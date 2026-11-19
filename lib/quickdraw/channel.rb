# frozen_string_literal: true

# Length-prefixed Marshal messages over a pair of pipes. Core Ruby only, since
# both ends may live in a process that runs user code.
class Quickdraw::Channel
	def self.pair
		down_reader, down_writer = IO.pipe
		up_reader, up_writer = IO.pipe

		[new(up_reader, down_writer), new(down_reader, up_writer)]
	end

	def initialize(reader, writer)
		@reader = reader
		@writer = writer
		@writer.sync = true
		# A worker's watchdog thread can write while its main thread is mid-message.
		@write_lock = Thread::Mutex.new
	end

	attr_reader :reader

	# Returns false if the other end has gone away.
	def write(message)
		data = Marshal.dump(message)
		@write_lock.synchronize { @writer.write([data.bytesize].pack("N"), data) }
		true
	rescue Errno::EPIPE
		false
	end

	# Returns nil if the other end has gone away, including mid-message.
	def read
		header = @reader.read(4)
		return unless header&.bytesize == 4

		size = header.unpack1("N")
		data = @reader.read(size)
		return unless data&.bytesize == size

		Marshal.load(data)
	rescue Errno::ECONNRESET
		nil
	end

	def close
		@reader.close unless @reader.closed?
		@writer.close unless @writer.closed?
	end
end
