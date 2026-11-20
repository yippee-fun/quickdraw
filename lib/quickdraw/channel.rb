# frozen_string_literal: true

# Length-prefixed Marshal messages over a pair of pipes. Core Ruby only, since
# both ends may live in a process that runs user code.
class Quickdraw::Channel
	def self.pair
		down_reader, down_writer = IO.pipe
		up_reader, up_writer = IO.pipe

		[new(up_reader, down_writer), new(down_reader, up_writer)]
	end

	# Bytes #read_available read of a message that hadn't all arrived.
	READ_SIZE = 65_536
	# Reads #read_available makes at most, so a fast writer can't keep it reading.
	READS_AT_ONCE = 16

	def initialize(reader, writer)
		@reader = reader
		@writer = writer
		@buffer = "".b
		@writer.sync = true
		# A worker's watchdog thread can write while its main thread is mid-message.
		@write_lock = Thread::Mutex.new
	end

	attr_reader :reader
	attr_reader :writer

	# A message as it's written: its length, then its data.
	def self.encode(message)
		data = Marshal.dump(message)
		[data.bytesize].pack("N") << data
	end

	# Returns false if the other end has gone away.
	def write(message)
		data = self.class.encode(message)
		@write_lock.synchronize { @writer.write(data) }
		true
	rescue Errno::EPIPE
		false
	end

	# Returns nil if the other end has gone away, including mid-message. Reads
	# only what the message needs, so a message still in the pipe shows as
	# readable.
	def read
		header = take(4) or return
		data = take(header.unpack1("N")) or return
		Marshal.load(data)
	rescue Errno::ECONNRESET
		nil
	end

	# Every message that has arrived, without waiting for more, then nil if the
	# other end has gone away. When messages come quickly, it reads many at
	# once, rather than making a read for each message's length and another for
	# its data.
	def read_available
		ended = false

		READS_AT_ONCE.times do
			case @reader.read_nonblock(READ_SIZE, exception: false)
			in String => chunk then @buffer << chunk
			in :wait_readable then break
			in nil
				ended = true
				break
			end
		end

		messages = []
		offset = 0

		while @buffer.bytesize - offset >= 4
			size = @buffer.byteslice(offset, 4).unpack1("N")
			break if @buffer.bytesize - offset - 4 < size

			messages << Marshal.load(@buffer.byteslice(offset + 4, size))
			offset += 4 + size
		end

		@buffer = @buffer.byteslice(offset..) if offset > 0
		messages << nil if ended
		messages
	rescue Errno::ECONNRESET
		[*messages, nil]
	end

	# `size` bytes: those #read_available left, then from the pipe.
	private def take(size)
		if @buffer.empty?
			data = @reader.read(size)
			data if data&.bytesize == size
		elsif @buffer.bytesize >= size
			data = @buffer.byteslice(0, size)
			@buffer = @buffer.byteslice(size..)
			data
		else
			rest = @reader.read(size - @buffer.bytesize)
			return unless rest&.bytesize == size - @buffer.bytesize

			data = @buffer << rest
			@buffer = "".b
			data
		end
	end

	def close
		@reader.close unless @reader.closed?
		@writer.close unless @writer.closed?
	end
end
