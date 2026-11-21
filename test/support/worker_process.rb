# frozen_string_literal: true

# Runs a real Quickdraw::Worker in a fork, as a loader does, for a test to play
# the coordinator: to send it commands and see exactly what it sends back.
module WorkerProcess
	class Session
		def initialize(channel, paths)
			@channel = channel
			@paths = paths
		end

		attr_reader :channel

		# The descriptions of the file's tests, in the order their indices are in.
		def load(name)
			@channel.write([:load, @paths.fetch(name)])

			case @channel.read
			in [:loaded, _path, tests, _seconds] then tests.map { |test| test["description"] }
			in [:load_failed, _path, error] then raise "#{name} failed to load: #{error['message']}"
			end
		end

		# Runs the tests at `indices` as one batch. Returns every message the
		# worker sent until it was ready for another, or until it exited, which
		# a last nil shows.
		def run(name, indices)
			@channel.write([:run, @paths.fetch(name), indices])
			messages = []

			loop do
				case @channel.read
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
	def start_worker(files, leaks: nil, timeouts: false)
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
		Session.new(coordinator, paths)
	end
end
