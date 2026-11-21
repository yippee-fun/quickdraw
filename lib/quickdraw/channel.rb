# frozen_string_literal: true

# Length-prefixed messages over a pair of pipes: anything Marshal can dump, or
# integers alone, which are several times quicker to pack and to read, and
# wait to be sent together (see #queue). Core Ruby only, since both ends may
# live in a process that runs user code.
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
	# Set in the length of a message that's queued integers, not Marshal data.
	INTEGERS = 0x8000_0000

	def initialize(reader, writer)
		@reader = reader
		@writer = writer
		@buffer = "".b
		@queued = []
		@writer.sync = true
		# A worker's watchdog thread can write while its main thread is
		# mid-message, or queueing.
		@write_lock = Thread::Mutex.new
	end

	attr_reader :reader
	attr_reader :writer

	# A message as it's written: its length, then its data.
	def self.encode(message)
		data = Marshal.dump(message)
		raise ArgumentError, "A message can't be #{data.bytesize} bytes, which is too long." if data.bytesize >= INTEGERS

		[data.bytesize].pack("N") << data
	end

	# After what's queued, in the same write, so messages arrive in the order
	# they were made. Returns false if the other end has gone away.
	def write(message)
		data = self.class.encode(message)
		@write_lock.synchronize { @writer.write(@queued.empty? ? data : dequeue << data) }
		true
	rescue Errno::EPIPE
		false
	end

	# Adds integers, each of up to 64 bits, to those the next #write or #flush
	# sends as one message, which is read as [:integers, integers]. Returns
	# how many are waiting.
	def queue(*integers)
		@write_lock.synchronize { @queued.concat(integers).size }
	end

	# Sends what's queued, if anything. Returns false if the other end has gone away.
	def flush
		@write_lock.synchronize { @writer.write(dequeue) unless @queued.empty? }
		true
	rescue Errno::EPIPE
		false
	end

	# Returns nil if the other end has gone away, including mid-message. Reads
	# only what the message needs, so a message still in the pipe shows as
	# readable.
	def read
		header = take(4) or return
		length = header.unpack1("N")
		data = take(length & ~INTEGERS) or return
		decode(length, data)
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
		available = @buffer.bytesize

		while available - offset >= 4
			length = @buffer.unpack1("N", offset:)
			size = length & ~INTEGERS
			break if available - offset - 4 < size

			messages << decode(length, @buffer.byteslice(offset + 4, size))
			offset += 4 + size
		end

		@buffer = @buffer.byteslice(offset..) if offset > 0
		messages << nil if ended
		messages
	rescue Errno::ECONNRESET
		[*messages, nil]
	end

	private def decode(length, data)
		(length & INTEGERS == 0) ? Marshal.load(data) : [:integers, data.unpack("q<*")]
	end

	# The queued integers as a message, which empties the queue.
	private def dequeue
		data = @queued.pack("q<*")
		@queued.clear
		[INTEGERS | data.bytesize].pack("N") << data
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
