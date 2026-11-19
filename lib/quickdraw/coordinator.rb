# frozen_string_literal: true

# Schedules tests across workers and feeds their results to a reporter. Never
# loads user code.
#
# Workers load files lazily. Batches from a file start at one test and double
# while the file's tests stay under the batch budget, so a slow file never
# hands all of its tests to one worker. Once every file is loaded, idle workers
# steal from the file with the most estimated time left, loading it themselves
# when that's worth more than the cost of loading.
class Quickdraw::Coordinator
	BATCH_BUDGET = 0.02

	class TestFile
		# `keys` are the tests' history keys, or nil without history. `indices` are
		# the tests to run. `prior_average` is the average test duration from
		# history, used until this run has its own measurements.
		def initialize(path:, display_path:, tests:, keys:, indices:, load_duration:, prior_average:, random:)
			@path = path
			@display_path = display_path
			@tests = tests
			@keys = keys
			@load_duration = load_duration
			@prior_average = prior_average
			@pending = indices.shuffle(random:)

			# With history, the first batch can fill the budget, up to a quarter of the
			# file in case its tests have got slower since.
			@batch_size = if prior_average
				(BATCH_BUDGET / [prior_average, 1e-9].max).floor.clamp(1, [@pending.size / 4, 1].max)
			else
				1
			end
			@total_duration = 0.0
			@completed = 0
		end

		attr_reader :path, :display_path, :tests, :keys, :pending, :load_duration

		def next_batch
			average = average_duration
			size = average ? [@batch_size, (BATCH_BUDGET / [average, 1e-9].max).floor].min : 1
			size = size.clamp(1, @pending.size)
			@batch_size = size * 2
			@pending.shift(size)
		end

		def record(duration)
			@total_duration += duration
			@completed += 1
		end

		def average_duration
			(@completed > 0) ? @total_duration / @completed : @prior_average
		end

		def estimated_pending_time
			average = average_duration
			average * @pending.size if average
		end
	end

	class Worker
		def initialize(channel, index)
			@channel = channel
			@index = index
			@loaded = {}
			@loading = nil
			@batch = nil
			@started = false
			@idle = false
			@pid = nil
			@sequence = 0
		end

		attr_reader :channel, :index, :loaded
		attr_accessor :loading, :batch, :started, :idle, :pid

		# The position of the next test in this worker's run order.
		def next_sequence
			@sequence += 1
		end

		# A child process the worker forked can hold its pipe open after it dies,
		# so EOF alone can't be relied on.
		def alive?
			return true unless @pid

			Process.kill(0, @pid)
			true
		rescue Errno::ESRCH
			false
		end
	end

	# `processes` is nil to choose the worker count automatically, from `cores`
	# up to `max_processes`. `selection` identifies what was asked for, so runs
	# of the same selection can be compared. `history_path` is nil to run without
	# history. `only_keys` limits each file to the tests with those history keys
	# (a Hash keyed by key), except files in `whole_files`, which run in full.
	def initialize(files:, processes:, cores:, max_processes:, seed:, reporter:, selection: "", history_path: nil, only_keys: nil, whole_files: {})
		@seed = seed
		@processes = processes
		@cores = cores
		@max_processes = max_processes
		@selection = selection
		@reporter = reporter
		@history_path = history_path
		@only_keys = only_keys
		@whole_files = whole_files
		@unloaded = files.shuffle(random: Random.new(seed)).map do |path|
			absolute = File.expand_path(path)
			[absolute, absolute.delete_prefix("#{Dir.pwd}/")]
		end
		@display_paths = @unloaded.to_h
		@files = {}
		@averages = {}
		@records = []
		@load_errors = []
	end

	def call
		started_at = Time.now
		forking = Process.respond_to?(:fork)

		# A channel for every worker there could be, since the count is chosen
		# after the loader forks.
		capacity = forking ? channel_capacity(@processes || @max_processes) : 1
		pairs = Array.new(capacity) { Quickdraw::Channel.pair }
		coordinator_channels = pairs.map(&:first)
		worker_channels = pairs.map(&:last)

		test_files = @unloaded.map(&:first)

		if forking
			control, control_writer = IO.pipe

			loader = Process.fork do
				coordinator_channels.each(&:close)
				control_writer.close
				exit(Quickdraw::Loader.new(worker_channels, test_files, @seed, control:).call)
			end

			worker_channels.each(&:close)
			control.close
		else
			Quickdraw::Loader.new(worker_channels, test_files, @seed).call_in_thread
		end

		begin
			# After forking, so sqlite3 never reaches the loader. Overlaps with its boot.
			open_history
			processes, @worker_choice = forking ? choose_processes(capacity) : [1, "default"]
		ensure
			# The loader waits for this, so it's always sent: zero if choosing failed.
			tell_loader(control_writer, processes || 0) if control_writer
		end

		coordinator_channels.drop(processes).each(&:close)
		@processes = processes
		@workers = coordinator_channels.first(processes).each_with_index.to_h { |channel, index| [channel.reader, Worker.new(channel, index)] }
		@reporter.start(processes:, worker_choice: @worker_choice, seed: @seed)

		until @workers.empty?
			readable, = IO.select(@workers.keys, nil, nil, 1)

			if readable
				readable.each do |io|
					worker = @workers[io]
					handle(worker, worker.channel.read) if worker
				end
			else
				@workers.values.reject(&:alive?).each { |worker| crashed(worker) }
			end

			dispatch
		end

		processes_failed = loader ? !Process.wait2(loader).last.success? : false

		passed = @reporter.finish(
			not_run: @unloaded.size + @files.each_value.sum { |file| file.pending.size },
			processes_failed: processes_failed || @history_unavailable,
		)

		# Written after the report, so it never delays the results.
		save_history(started_at, passed)
		passed
	end

	private def open_history
		return unless @history_path

		@history = Quickdraw::History.new(@history_path)
		@averages = @history.average_durations
		@file_durations = @history.file_durations
		order_slowest_files_first(@file_durations)
	rescue Quickdraw::History::Error => error
		@history = nil

		if @only_keys
			# --failed can't pick out the failing tests without history.
			warn "Quickdraw couldn’t open its run history (#{error.message}), so --failed has nothing to run."
			@unloaded = []
			@history_unavailable = true
		else
			warn "Quickdraw couldn’t open its run history (#{error.message}). Continuing without it."
		end
	end

	# Returns [count, how it was chosen].
	private def choose_processes(capacity)
		return [@processes.clamp(1, capacity), "manual"] if @processes
		return [@cores.clamp(1, capacity), "default"] unless @history

		choice = Quickdraw::WorkerTuner.new(cores: @cores, max: capacity).choose(
			# --failed runs a different subset each time, so its timings aren't comparable.
			runs: @only_keys ? [] : @history.recent_runs(@selection),
			expected: @history.expected(@unloaded.map(&:last)),
			waiting_share: @history.last_waiting_share(@selection),
		)

		[choice.processes, choice.reason]
	rescue Quickdraw::History::Error => error
		warn "Quickdraw couldn’t read its run history (#{error.message})."
		[@cores.clamp(1, capacity), "default"]
	end

	private def tell_loader(writer, processes)
		writer.puts(processes)
	rescue Errno::EPIPE
		# The loader has already exited; its workers' channels report that.
		nil
	ensure
		writer.close
	end

	# Each worker needs four file descriptors. Raises the soft limit if needed,
	# and otherwise caps the number of workers to fit around those already open.
	private def channel_capacity(wanted)
		reserved = open_file_descriptors + 32
		soft, hard = Process.getrlimit(:NOFILE)
		needed = (wanted * 4) + reserved

		if soft < needed
			begin
				Process.setrlimit(:NOFILE, [needed, hard].min, hard)
			rescue Errno::EINVAL, Errno::EPERM
				nil
			end

			soft, = Process.getrlimit(:NOFILE)
		end

		wanted.clamp(1, [(soft - reserved) / 4, 1].max)
	end

	private def open_file_descriptors
		Dir.children("/dev/fd").size
	rescue SystemCallError
		64
	end

	private def save_history(started_at, passed)
		return unless @history

		@history.record_run(
			started_at:,
			finished_at: Time.now,
			seed: @seed,
			processes: @processes,
			worker_choice: @worker_choice,
			selection: @selection,
			passed:,
			records: @records,
			loaded_paths: @files.each_value.map(&:display_path),
			load_errors: @load_errors,
		)
		@history.close
	rescue Quickdraw::History::Error => error
		warn "Quickdraw couldn’t save this run to its history (#{error.message})."
	end

	# Files with no history go first, since they could be slow too. The rest go
	# slowest first, so the longest files don't start last.
	private def order_slowest_files_first(durations)
		@unloaded = @unloaded.each_with_index.sort_by do |(_absolute, display), index|
			duration = durations[display]
			(duration > 0) ? [1, -duration, index] : [0, 0, index]
		end.map(&:first)
	end

	private def handle(worker, message)
		case message
		in nil
			crashed(worker)
		in [:ready, pid]
			worker.pid = pid
			worker.idle = true
		in [:started]
			worker.started = true
		in [:loaded, path, tests, load_duration]
			loaded(worker, path, tests, load_duration)
		in [:load_failed, path, error]
			worker.loading = nil
			worker.loaded[path] = false
			worker.idle = true
			load_failed(path, error) unless @files.key?(path)
		in [:result, index, result]
			record(worker, index, result)
		end
	end

	private def loaded(worker, path, tests, load_duration)
		worker.loading = nil
		worker.loaded[path] = true
		worker.idle = true

		if (file = @files[path])
			unless file.tests == tests
				raise "#{file.display_path} defined different tests when loaded in a second worker."
			end
		else
			display_path = display_path(path)
			keys = @history&.keys(display_path, tests)
			indices = Array.new(tests.size) { |index| index }

			if @only_keys && !@whole_files.key?(display_path)
				indices.select! { |index| @only_keys.key?(keys[index]) }
			end

			known = keys&.filter_map { |key| @averages[key] } || []

			@files[path] = TestFile.new(
				path:,
				display_path:,
				tests:,
				keys:,
				indices:,
				load_duration:,
				prior_average: (known.sum / known.size if known.any?),
				random: Random.new(Quickdraw.stable_hash("#{@seed}:#{display_path}")),
			)
		end
	end

	private def record(worker, index, result)
		file, indices = worker.batch
		expected = indices.shift
		raise "Expected a result for test #{expected} but got #{index}." unless expected == index

		worker.batch = nil if indices.empty?
		to_seconds(result)
		file.record(result["duration"])
		report(worker, file, index, result)
	end

	ALLOCATIONS = Quickdraw::STATS.index("allocations")

	# Workers send nanosecond integers, which are much cheaper to send than floats.
	private def to_seconds(result)
		result["duration"] /= 1e9
		result["stats"] = result["stats"].each_with_index.map { |value, index| (index == ALLOCATIONS) ? value : value / 1e9 }
	end

	private def report(worker, file, index, result)
		@reporter.result(file.display_path, file.tests[index], result)

		if @history
			@records << Quickdraw::History::Record.new(
				key: file.keys[index],
				path: file.display_path,
				test: file.tests[index],
				result:,
				worker: worker.index,
				sequence: worker.next_sequence,
			)
		end
	end

	private def load_failed(path, error)
		display_path = display_path(path)
		@reporter.load_failed(display_path, error)
		@load_errors << [display_path, error]
	end

	private def crashed(worker)
		@workers.delete(worker.channel.reader)
		worker.channel.close

		crash = {
			"name" => "Quickdraw::WorkerCrashed",
			"message" => "The worker process exited unexpectedly.",
			"backtrace" => [],
		}

		if (path = worker.loading)
			load_failed(path, crash) unless @files.key?(path)
		elsif (batch = worker.batch)
			file, indices = batch

			if worker.started
				index, *rest = indices
				file.pending.unshift(*rest)
				report(worker, file, index, {
					"assertions" => 0, "failures" => [], "errors" => [crash], "duration" => nil
				})
			else
				file.pending.unshift(*indices)
			end
		end
	end

	private def dispatch
		idle = @workers.each_value.select(&:idle)
		all_idle = idle.size == @workers.size

		idle.each do |worker|
			if (file = own_file(worker))
				run_batch(worker, file)
			elsif (path, = @unloaded.shift)
				load(worker, path)
			elsif (file = file_to_steal(worker, all_idle))
				load(worker, file.path)
			end
		end

		return unless all_idle && @workers.each_value.all?(&:idle)

		@workers.each_value { |worker| worker.channel.write([:stop]) }
		@workers.clear
	end

	private def own_file(worker)
		worker.loaded
			.filter_map { |path, loaded| @files.fetch(path) if loaded }
			.select { |file| file.pending.any? }
			.max_by { |file| file.pending.size }
	end

	# When every worker is idle, nothing else will pick up the work, so steal regardless of cost.
	private def file_to_steal(worker, all_idle)
		candidates = @files.each_value.reject { |file| worker.loaded.key?(file.path) || file.pending.empty? }

		unless all_idle
			candidates.select! do |file|
				estimate = file.estimated_pending_time
				estimate && estimate > file.load_duration * 2
			end
		end

		candidates.max_by { |file| file.estimated_pending_time || 0 }
	end

	private def run_batch(worker, file)
		indices = file.next_batch
		worker.batch = [file, indices.dup]
		worker.started = false
		worker.idle = false
		crashed(worker) unless worker.channel.write([:run, file.path, indices])
	end

	private def load(worker, path)
		worker.loading = path
		worker.idle = false
		crashed(worker) unless worker.channel.write([:load, path])
	end

	private def display_path(path)
		@display_paths.fetch(path)
	end
end
