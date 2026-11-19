# frozen_string_literal: true

# Serves the app to the worker's browser with Puma, in threads of the worker,
# so with config.rails they share the test's database transaction. It counts
# requests in progress, until Puma has run their completion callbacks, so a test
# can wait for its page's to finish, and keeps what the app raised (from its
# body too), to raise in the test.
class Quickdraw::Browser::Server
	THREADS = 8

	# Raised when a test's requests outlast it. They may change the database
	# outside its transaction, so the worker's later browser tests raise it too.
	class Stuck < StandardError; end

	def initialize(app, port:)
		@app = app
		@mutex = Thread::Mutex.new
		@idle = Thread::ConditionVariable.new
		@requests = 0
		@errors = []
		@finished = -> (*) { finished }

		@puma = Puma::Server.new(self, nil,
			min_threads: 0,
			max_threads: THREADS,
			log_writer: Puma::LogWriter.null,
			environment: "test",
			# Not for a browser disconnecting, which Puma ignores.
			lowlevel_error_handler: -> (error, _env, status) { raised(error, status) },
		)
		@puma.add_tcp_listener("127.0.0.1", port)
		@url = "http://127.0.0.1:#{@puma.connected_ports.first}"
		@puma.run
	end

	attr_reader :url

	# The Stuck error, once a test's requests have outlasted it.
	attr_reader :stuck

	def call(env)
		@mutex.synchronize { @requests += 1 }
		# First, since Puma calls them in reverse, so it's called after the app's.
		(env["rack.response_finished"] ||= []).unshift(@finished)
		@app.call(env)
	end

	def errors? = @mutex.synchronize { @errors.any? }

	# Waits up to `timeout` seconds for requests in progress to finish, then
	# raises the first error the app raised since the last call.
	def finish(timeout)
		deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

		error = @mutex.synchronize do
			while @requests > 0
				remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)

				if remaining <= 0
					@stuck = Stuck.new("The app was still serving #{@requests} #{(@requests == 1) ? 'request' : 'requests'} #{timeout}s after a test closed its page, so this worker can’t run more browser tests.")
					raise @stuck
				end

				@idle.wait(@mutex, remaining)
			end

			@errors.shift.tap { @errors.clear }
		end

		raise error if error
	end

	# The page shows the error, so it's in the screenshot.
	private def raised(error, status)
		@mutex.synchronize { @errors << error }
		[status, { "content-type" => "text/plain" }, ["#{error.class}: #{error.message}"]]
	end

	private def finished
		@mutex.synchronize do
			@requests -= 1
			@idle.broadcast if @requests == 0
		end
	end
end
