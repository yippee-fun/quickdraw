# frozen_string_literal: true

class ChannelTest < Quickdraw::Test
	def pair
		reader, writer = Quickdraw::Channel.pair
		defer { [reader, writer].each(&:close) }
		[reader, writer]
	end

	test "reads each message as it was written" do
		reader, writer = pair

		assert writer.write([:loaded, "a.test.rb", [{ "line" => 1 }], 0.5])
		assert writer.write(nil)

		assert_equal reader.read, [:loaded, "a.test.rb", [{ "line" => 1 }], 0.5]
		assert_nil reader.read
	end

	test "sends queued integers as one message, with the next write and before it" do
		reader, writer = pair

		assert_equal writer.queue(1, 2, 3), 3
		assert_equal writer.queue(4, 5), 5
		assert_nil reader.reader.wait_readable(0.01)
		writer.write([:ready, 1])

		assert_equal reader.read, [:integers, [1, 2, 3, 4, 5]]
		assert_equal reader.read, [:ready, 1]
	end

	test "flush sends what's queued, and nothing when nothing is" do
		reader, writer = pair

		assert writer.flush
		assert_nil reader.reader.wait_readable(0.01)

		writer.queue(7)
		assert writer.flush
		assert writer.flush
		assert_equal writer.queue(8), 1
		writer.flush

		assert_equal reader.read_available, [[:integers, [7]], [:integers, [8]]]
	end

	test "queued integers can be any that fit in 64 bits, negative too" do
		reader, writer = pair
		integers = [0, -1, 1, (2 ** 63) - 1, -(2 ** 63), 1_700_000_000_000_000_000]

		writer.queue(*integers)
		writer.flush

		assert_equal reader.read, [:integers, integers]
	end

	test "read_available reads every message that has arrived, of either kind, in order" do
		reader, writer = pair

		writer.write([:started])
		writer.queue(1, 2)
		writer.write([:result, 3, { "failures" => [] }])
		writer.queue(4)
		writer.flush

		assert_equal reader.read_available, [[:started], [:integers, [1, 2]], [:result, 3, { "failures" => [] }], [:integers, [4]]]
		assert_equal reader.read_available, []
	end

	test "read_available keeps part of a message until the rest arrives" do
		reader, writer = pair
		integers = (1..9).to_a
		data = integers.pack("q<*")
		message = [Quickdraw::Channel::INTEGERS | data.bytesize].pack("N") << data << Quickdraw::Channel.encode([:ready, 1])

		writer.writer.write(message.byteslice(0, 2))
		assert_equal reader.read_available, []
		writer.writer.write(message.byteslice(2, 30))
		assert_equal reader.read_available, []
		writer.writer.write(message.byteslice(32..))

		assert_equal reader.read_available, [[:integers, integers], [:ready, 1]]
	end

	test "read reads what read_available left, then from the pipe" do
		reader, writer = pair
		writer.queue(1, 2, 3)
		writer.flush
		writer.queue(4)
		message = Quickdraw::Channel.encode([:ready, 1])
		writer.writer.write(message.byteslice(0, 3))

		assert_equal reader.read_available, [[:integers, [1, 2, 3]]]

		writer.writer.write(message.byteslice(3..))
		writer.flush

		assert_equal reader.read, [:ready, 1]
		assert_equal reader.read, [:integers, [4]]
	end

	test "says when the other end has gone away" do
		reader, writer = pair
		writer.queue(1)
		writer.flush
		writer.close

		assert_equal reader.read_available, [[:integers, [1]], nil]
		assert_nil reader.read

		reader.reader.close
		other_reader, other_writer = pair
		other_reader.close
		other_writer.queue(1)

		refute other_writer.flush
		refute other_writer.write([:ready, 1])
	end

	# A worker's watchdog writes that a test timed out while its main thread
	# may be queueing that test's result.
	test "every queued integer arrives once, in order, while another thread writes" do
		reader, writer = pair
		count = 20_000
		received = []
		ticks = 0

		reading = Thread.new do
			while (message = reader.read)
				case message
				in [:integers, integers] then received.concat(integers)
				in [:tick] then ticks += 1
				end
			end
		end

		started = Thread::Queue.new
		writing = Thread.new { started.pop; 2_000.times { writer.write([:tick]) } }

		queueing = Thread.new do
			started.pop

			count.times do |number|
				writer.queue(number, -number)
				Thread.pass if number % 10 == 0
			end
		end

		2.times { started << true }
		[queueing, writing].each(&:join)
		writer.flush
		writer.writer.close
		reading.join

		assert_equal ticks, 2_000
		assert_equal received.size, count * 2
		assert_equal received, Array.new(count) { |number| [number, -number] }.flatten
	end
end
