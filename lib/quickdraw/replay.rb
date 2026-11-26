# frozen_string_literal: true

# Runs tests in an exact order in one worker process, with a run's seed and
# worker slot, to find out whether a test's outcome depends on the tests
# before it.
#
# Processes are as in a run: a loader boots config once (and the group's
# setup, for tests in a group), then forks a new worker for each attempt, so
# attempts can't affect each other. Each file loads when its first test is
# reached, as in a run. What tests print is discarded.
class Quickdraw::Replay
	# `path` is absolute.
	Step = Data.define(:path, :line, :name)

	# Config or a group's setup raised. `error` is serialized, as by Quickdraw.serialize_error.
	class BootFailed < StandardError
		def initialize(error)
			@error = error
			super("#{error['name']}: #{error['message']}")
		end

		attr_reader :error
	end

	# How often to check that a worker is still alive while waiting for it.
	LIVENESS_INTERVAL = 0.5

	# The tests' group comes from the first loader's report. If they're in
	# one, that loader stops and one for the group starts: the one with
	# `variant`, for tests that ran in a group with one (see Configuration::Group).
	def initialize(paths, seed:, slot:, attempts:, variant: nil)
		@paths = paths
		@seed = seed
		@slot = slot
		@attempts = 0
		@channel_count = attempts

		groups = boot(nil)
		display_paths = paths.map { |path| path.delete_prefix("#{Dir.pwd}/") }
		group, _patterns, gemfile = groups.find do |_name, patterns, *, group_variant|
			(variant.nil? || group_variant == variant) &&
				display_paths.any? { |path| patterns.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) } }
		end

		return unless group

		stop
		boot(group, gemfile:)
	end

	attr_reader :attempts

	def attempts_left = @channels.size - @attempts

	# The status of each step: passed, failed, errored, skipped or pending;
	# missing if the test can't be found; crashed if the worker died running it
	# or loading its file; or not run if it died before.
	def call(steps)
		raise "No attempts left." if @attempts == @channels.size

		index = @attempts
		@attempts += 1
		@channel = @channels.fetch(index)
		@pid = nil
		@control.puts("fork #{index} #{@slot}")
		tests = {}
		statuses = []
		# What each test that passed gathered, by [path, index].
		gathered_by = {}

		return Array.new(steps.size, "crashed") unless expect(:ready)

		steps.each do |step|
			unless tests.key?(step.path)
				@channel.write([:load, step.path])

				case expect(:loaded, :load_failed)
				in [:loaded, _path, loaded, _duration] then tests[step.path] = loaded
				in [:load_failed, *] then tests[step.path] = []
				in nil then break statuses << "crashed"
				end
			end

			test_index = find(tests.fetch(step.path), step) or next statuses << "missing"
			@channel.write([:run, step.path, [test_index], gathered_for(tests.fetch(step.path), step.path, test_index, gathered_by)])

			case expect(:result, :integers)
			in [:result | :integers, *] => message
				Quickdraw::Worker.each_result(message) do |_index, result|
					status = Quickdraw::Outcome.status(result)
					gathered_by[[step.path, test_index]] = result.fetch("gathered", []) if status == "passed"
					statuses << status
				end
				expect(:ready)
			in nil
				break statuses << "crashed"
			end
		end

		statuses.fill("not run", statuses.size, steps.size - statuses.size)
	ensure
		@channel&.write([:stop])
		@channel&.close
		# The next attempt uses the same slot, so not until this worker's at_exit
		# hooks have finished with its resources.
		sleep 0.01 while @pid && alive?(@pid)
	end

	def stop
		@control.close
		@channels.each(&:close)
		Process.wait(@loader) unless @loader_status
	end

	# Starts a loader for `group` and waits for it to boot. Returns the groups
	# config defines, or raises BootFailed.
	private def boot(group, gemfile: nil)
		@loader_status = nil
		pairs = Array.new(@channel_count) { Quickdraw::Channel.pair }
		@channels = pairs.map(&:first)
		worker_channels = pairs.map(&:last)
		control, @control = IO.pipe
		report, report_writer = IO.pipe

		@loader = Quickdraw::Loader.start(worker_channels, @paths, @seed, gemfile:, quiet: true, control:, group:, report: report_writer) do
			@channels.each(&:close)
			@control.close
			report.close
		end

		worker_channels.each(&:close)
		control.close
		report_writer.close

		case read_report(report)
		in [:booted, groups, *] then groups
		in [:failed, error] then raise BootFailed.new(error)
		in nil then raise BootFailed.new({ "name" => "Quickdraw::LoaderCrashed", "message" => "The process that loads config exited while booting." })
		end
	end

	# Waits for the loader's report, or for it to exit without one.
	private def read_report(report)
		until report.wait_readable(LIVENESS_INTERVAL)
			return if loader_exited?
		end

		header = report.read(4)
		return unless header&.bytesize == 4

		size = header.unpack1("N")
		data = report.read(size)
		# Short if the loader died while writing.
		Marshal.load(data) if data&.bytesize == size
	ensure
		report.close
	end

	# Reads until a message of one of `types`, or nil once the worker has gone,
	# whether its pipe closed or, since a process it started can hold that
	# open, its process is no longer running.
	private def expect(*types)
		loop do
			unless @channel.reader.wait_readable(LIVENESS_INTERVAL)
				# Until the worker reports its pid, it's alive if the loader is.
				running = @pid ? alive?(@pid) : !loader_exited?
				running ? next : return
			end

			message = @channel.read or return
			@pid = message.last if message.first in :pid | :ready
			return message if types.include?(message.first)
		end
	end

	private def loader_exited?
		@loader_status ||= Process.wait2(@loader, Process::WNOHANG)&.last
	end

	private def alive?(pid)
		Process.kill(0, pid)
		true
	rescue Errno::ESRCH
		false
	end

	# By name and line, then by name alone, since lines move as files change.
	private def find(tests, step)
		named = tests.each_index.select { |index| Quickdraw::Filter.name_of(tests[index]) == step.name }
		named.find { |index| tests[index]["line"] == step.line } || named.first
	end

	# For an after_tests test, what the tests it follows gathered, if they all
	# passed earlier in the replay. Otherwise nothing, so it skips.
	private def gathered_for(tests, path, index, gathered_by)
		follows = tests[index]["follows"] or return {}
		gathered = follows.map { |followed| gathered_by[[path, followed]] }
		gathered.include?(nil) ? {} : { index => gathered.flatten(1) }
	end
end
