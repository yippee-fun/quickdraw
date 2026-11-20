# frozen_string_literal: true

require "json"

# The worker's Node process, running bridge.mjs, which runs Playwright. Each
# request is a line of JSON on its input, answered by a line on its output.
class Quickdraw::Browser::Bridge
	SCRIPT = File.join(__dir__, "bridge.mjs").freeze
	READ_SIZE = 65_536

	# Starts Node, which launches the browser and opens the first pages while
	# the worker loads test files. `settings` are bridge.mjs's.
	def initialize(node:, playwright:, settings:, log:)
		@log = log
		@id = 0
		@unanswered = Set.new
		@buffer = "".b
		# How much of the buffer has no newline.
		@scanned = 0
		@mutex = Thread::Mutex.new
		input, @writer = IO.pipe
		@reader, output = IO.pipe
		# In a process group of its own, so Ctrl-C reaches the worker, which
		# closes Node's input, and Node closes the browser.
		@pid = Process.spawn(node, SCRIPT, playwright, JSON.generate(settings), in: input, out: output, err: [log, "w"], pgroup: true)
		input.close
		output.close
		@reader.binmode
		@writer.binmode
	end

	# Sends `operation` (see bridge.mjs) and returns its result. One at a time,
	# so each thread reads its own reply.
	def call(operation, **params)
		@mutex.synchronize { request(operation, params) }
	end

	# Closes Node's input, so it closes the browser, then waits up to `timeout`
	# seconds for it to exit before killing it.
	def stop(timeout: 2)
		@writer.close unless @writer.closed?
		deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

		until Process.wait(@pid, Process::WNOHANG)
			if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
				Process.kill(:KILL, -@pid)
				Process.wait(@pid)
				break
			end

			sleep 0.01
		end
	rescue Errno::ECHILD, Errno::ESRCH
		nil
	end

	private def request(operation, params)
		id = (@id += 1)
		json = "#{JSON.generate({ id:, op: operation, **params })}\n"

		# Whole, or Node would read the next request as the rest of this one.
		Thread.handle_interrupt(Object => :never) do
			@writer.write(json)
			@unanswered << id
		end

		message = reply(id)

		if (error = message["error"])
			raise ((error["name"] == "TimeoutError") ? Quickdraw::Browser::TimeoutError : Quickdraw::Browser::Error), error["message"]
		end

		message["result"]
	rescue Errno::EPIPE, IOError
		raise Quickdraw::Browser::Error, exited
	end

	# Skips the replies to earlier requests, which an exception, such as a
	# Timeout around a page call, stopped waiting for.
	private def reply(id)
		loop do
			message = JSON.parse(line)
			raise Quickdraw::Browser::Error, "Quickdraw’s Node process answered #{message['id']}, not #{id}." unless @unanswered.delete?(message["id"])
			return message if message["id"] == id
		end
	end

	# Not with gets, which loses what it has read of a line when an exception
	# interrupts it. Interrupts only stop the wait.
	private def line
		until (newline = @buffer.index("\n", @scanned))
			@scanned = @buffer.bytesize
			@reader.wait_readable

			Thread.handle_interrupt(Object => :never) do
				case @reader.read_nonblock(READ_SIZE, exception: false)
				in String => data then @buffer << data
				in :wait_readable then nil
				in nil then raise Quickdraw::Browser::Error, exited
				end
			end
		end

		@scanned = 0
		@buffer.slice!(0..newline).force_encoding(Encoding::UTF_8)
	end

	private def exited
		log = File.exist?(@log) ? File.readlines(@log, chomp: true).reject { |line| line.strip.empty? }.last(10) : []
		["Quickdraw’s Node process for Playwright exited.", *log].join("\n")
	end
end
