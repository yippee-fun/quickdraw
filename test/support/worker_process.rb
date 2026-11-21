# frozen_string_literal: true

# Runs a real Quickdraw::Worker in a fork, as a loader does, for a test to play
# the coordinator: to send it commands and see exactly what it sends back.
module WorkerProcess
	class Session
		def initialize(channel, paths, directory)
			@channel = channel
			@paths = paths
			@directory = directory
		end

		# A file beside the test files, which their tests see in __dir__.
		def path(name) = File.join(@directory, name)

		# The descriptions of the file's tests, in the order their indices are in.
		def load(name)
			@channel.write([:load, @paths.fetch(name)])

			case @channel.read
			in [:loaded, _path, tests, _seconds] then tests.map { |test| test["description"] }
			in [:load_failed, _path, error] then raise "#{name} failed to load: #{error['message']}"
			end
		end

		# Has the worker run the tests at `indices` as one batch.
		def start(name, indices)
			@channel.write([:run, @paths.fetch(name), indices])
		end

		# The next message the worker sends, or nil once it has exited.
		def read = @channel.read

		# Runs the tests at `indices` as one batch. Returns every message the
		# worker sent until it was ready for another, or until it exited, which
		# a last nil shows.
		def run(name, indices)
			start(name, indices)
			messages = []

			loop do
				case read
				in [:ready, _pid] then break
				in nil
					messages << nil
					break
				in message then messages << message
				end
			end

			messages
		end
	end

	# A worker with `files`, which maps names to sources, to load and run.
	# `timeout` is each test's, unless it has its own, with `timeouts`.
	# `unsent_time` is its Worker::UNSENT_TIME, which by default is too long
	# to reach, so a slow machine doesn't change which results are sent together.
	def start_worker(files, leaks: nil, timeouts: false, timeout: nil, unsent_time: 3_600_000_000_000)
		skip "Workers are forked" unless Process.respond_to?(:fork)

		directory = tmpdir
		paths = files.to_h { |name, _source| [name, File.join(directory, name)] }
		files.each { |name, source| File.write(paths.fetch(name), source) }
		coordinator, worker = Quickdraw::Channel.pair

		pid = Process.fork do
			coordinator.close
			Quickdraw::Leaks::ProcessStarts.watch if leaks && !Quickdraw::Leaks::ProcessStarts.watching?
			# This fork isn't a process the worker's tests started.
			Quickdraw::Leaks::ProcessStarts.started = false

			if timeout
				# Config is frozen once it's loaded.
				config = Quickdraw::Config.dup
				config.timeout = timeout
				Quickdraw.__send__(:remove_const, :Config)
				Quickdraw.const_set(:Config, config)
			end

			Quickdraw::Worker.__send__(:remove_const, :UNSENT_TIME)
			Quickdraw::Worker.const_set(:UNSENT_TIME, unsent_time)

			Quickdraw::Worker.new(worker, paths.values.to_h { |path| [path, true] }, 1, timeouts:, leaks:).call
		ensure
			exit!(0)
		end

		worker.close

		defer do
			coordinator.close

			begin
				Process.kill("KILL", pid)
			rescue Errno::ESRCH
				nil
			end

			Process.wait(pid)
		end

		assert_equal coordinator.read, [:ready, pid]
		Session.new(coordinator, paths, directory)
	end
end
