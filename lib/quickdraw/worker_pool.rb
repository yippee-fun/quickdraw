# frozen_string_literal: true

# Boots config in a loader and starts its workers, for commands that drive
# workers a message at a time rather than running tests through the
# coordinator, such as `quickdraw mutate` and `quickdraw fuzz`.
class Quickdraw::WorkerPool
	# How often to check that a worker is still alive while waiting for it.
	LIVENESS_INTERVAL = 0.5

	# A worker exited, or its pipe closed.
	class Gone < StandardError; end

	def initialize(test_files, processes:, seed:)
		@test_files = test_files
		@processes = processes
		@seed = seed
		@lock = Thread::Mutex.new
	end

	attr_reader :slots

	# Boots config and starts the workers. Returns the groups config defines,
	# as [name, patterns, gemfile], whose tests need loaders of their own.
	# Raises Replay::BootFailed if config raises.
	def start
		pairs = Array.new(@processes) { Quickdraw::Channel.pair }
		channels = pairs.map(&:first)
		worker_channels = pairs.map(&:last)
		control, @control = IO.pipe
		report, report_writer = IO.pipe

		@loader = Quickdraw::Loader.start(worker_channels, @test_files, @seed, quiet: true, control:, report: report_writer) do
			channels.each(&:close)
			@control.close
			report.close
		end

		worker_channels.each(&:close)
		control.close
		report_writer.close
		@slots = channels.map { |channel| Slot.new(channel, self) }

		groups = case read_report(report)
		in [:booted, groups, *] then groups
		in [:failed, error] then raise Quickdraw::Replay::BootFailed.new(error)
		in nil then raise Quickdraw::Replay::BootFailed.new({ "name" => "Quickdraw::LoaderCrashed", "message" => "The process that loads config exited while booting." })
		end

		@control.puts("start #{@processes}")
		groups
	end

	# Runs the block in a thread for each worker, and returns what each returned.
	def in_slots(&block)
		@slots.map { |slot| Thread.new(slot, &block) }.map(&:value)
	end

	def stop
		@control&.close
		@slots&.each(&:close)
		Process.wait(@loader) if @loader && !loader_exited?
	rescue Errno::ECHILD
		nil
	end

	def loader_exited?
		@lock.synchronize do
			@loader_status ||= Process.wait2(@loader, Process::WNOHANG)&.last
		end
	end

	# Waits for the loader's report, or for it to exit without one.
	private def read_report(report)
		until report.wait_readable(LIVENESS_INTERVAL)
			return if loader_exited?
		end

		header = report.read(4)
		data = report.read(header.unpack1("N")) if header&.bytesize == 4
		Marshal.load(data) if data
	ensure
		report.close
	end

	# A worker, and the test files it has loaded.
	class Slot
		def initialize(channel, pool)
			@channel = channel
			@pool = pool
			@pid = nil
			@files = {}
			@gone = false
		end

		# The file's tests, as Worker#describe gives them, or nil if it failed to load.
		def load(path)
			return @files[path] if @files.key?(path)

			write([:load, path])

			@files[path] = case expect(:loaded, :load_failed)
			in [:loaded, _path, tests, _duration] then tests
			in [:load_failed, *] then nil
			end
		end

		def write(message)
			raise Gone if @gone

			@channel.write(message) or gone!
		end

		# Reads until a message of one of `types`.
		def expect(*types)
			loop do
				message = read
				return message if types.include?(message.first)
			end
		end

		# The next message. Raises Gone once the worker has, whether its pipe
		# closed or, since a process it started can hold that open, its process
		# is no longer running.
		def read
			raise Gone if @gone

			loop do
				unless @channel.reader.wait_readable(LIVENESS_INTERVAL)
					# Until the worker reports its pid, it's alive if the loader is.
					next if @pid ? alive?(@pid) : !@pool.loader_exited?

					gone!
				end

				message = @channel.read or gone!
				return message unless message.first in :pid | :ready

				@pid = message.last
			end
		rescue IOError
			gone!
		end

		def close
			@channel.close
		end

		private def gone!
			@gone = true
			raise Gone
		end

		private def alive?(pid)
			Process.kill(0, pid)
			true
		rescue Errno::ESRCH
			false
		end
	end
end
