# frozen_string_literal: true

class WorkerTerminalTest < Quickdraw::Test
	Stopped = Class.new(StandardError)

	# A worker whose debugger asks for the terminal over `channel`, with
	# `turns` turns free.
	def worker(channel, turns:)
		Quickdraw::Worker.allocate.tap do |worker|
			worker.instance_variable_set(:@terminal_turn, Thread::Queue.new([true] * turns))
			worker.instance_variable_set(:@channel, channel)
		end
	end

	def turns(worker) = worker.instance_variable_get(:@terminal_turn).size

	test "gives its turn back when the coordinator doesn't give it the terminal" do
		coordinator, channel = Quickdraw::Channel.pair
		coordinator.reader.close
		coordinator.writer.close
		worker = worker(channel, turns: 1)

		error = assert_raises(RuntimeError) { worker.holding_terminal { raise "Held the terminal." } }

		assert_equal error.message, "Expected the coordinator to give this worker the terminal, but got nil."
		assert_equal turns(worker), 1
		refute worker.has_terminal?
	end

	test "an interrupt while it waits for its turn doesn't add a turn" do
		_coordinator, channel = Quickdraw::Channel.pair
		worker = worker(channel, turns: 0)
		waiting = Thread.new do
			Thread.current.report_on_exception = false
			worker.holding_terminal { raise "Held the terminal." }
		end
		defer { waiting.kill }

		Thread.pass until waiting.status == "sleep"
		waiting.raise(Stopped)

		assert_raises(Stopped) { waiting.join(5) }
		assert_equal turns(worker), 0
	end

	# Whether an interrupt waits for a blocking read that defers interrupts.
	def defers_interrupts_while_reading?
		reader, writer = IO.pipe
		line = nil
		reading = Thread.new do
			Thread.handle_interrupt(Object => :never) { line = reader.gets }
		rescue Stopped
			nil
		end

		Thread.pass until reading.status == "sleep"
		reading.raise(Stopped)
		writer.puts("read")
		reading.join
		line == "read\n"
	ensure
		reader.close
		writer.close
	end

	test "gives the debug gem's terminal back when an interrupt arrives while it asks for it" do
		skip "This Ruby interrupts a blocking read while interrupts are deferred" unless defers_interrupts_while_reading?

		coordinator, channel = Quickdraw::Channel.pair
		worker = worker(channel, turns: 1)
		taking = Thread.new do
			Thread.current.report_on_exception = false
			worker.take_terminal(:debug_gem)
		end
		defer { taking.kill }

		assert_equal coordinator.read, [:debugging]
		taking.raise(Stopped)
		coordinator.write([:debug])

		assert_raises(Stopped) { taking.join(5) }
		assert_equal coordinator.read, [:debugged]
		assert_equal turns(worker), 1
		refute worker.has_terminal?
	end

	test "keeps one turn when an interrupt arrives as its turn comes" do
		coordinator, channel = Quickdraw::Channel.pair
		coordinator.reader.close
		coordinator.writer.close

		left = Array.new(50) do
			worker = worker(channel, turns: 0)
			waiting = Thread.new do
				Thread.current.report_on_exception = false
				worker.holding_terminal { raise "Held the terminal." }
			end

			Thread.pass until waiting.status == "sleep"
			worker.instance_variable_get(:@terminal_turn) << true
			waiting.raise(Stopped)
			# Stopped, or, if it took the turn first, the closed channel's error.
			begin
				waiting.join(5)
			rescue Stopped, RuntimeError
				nil
			end

			turns(worker)
		end

		assert_equal left.uniq, [1]
	end
end
