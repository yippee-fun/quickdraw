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

	# Channels kept for replacing workers that crash.
	SPARE_CHANNELS = 4

	# How often to check for workers that died without closing their pipes, or
	# whose tests are stuck where the watchdog can't stop them, in seconds.
	LIVENESS_INTERVAL = 1

	# How long past a test's timeout to wait for its watchdog before killing it.
	TIMEOUT_GRACE = 5

	# How long to wait for teardown after Ctrl-C before reporting, in seconds.
	INTERRUPT_GRACE = 3

	class TestFile
		# `keys` are the tests' history keys, or nil without history. `indices` are
		# the tests to run. `prior_average` is the average test duration from
		# history, used until this run has its own measurements.
		def initialize(path:, display_path:, tests:, keys:, indices:, load_duration:, prior_average:, random:)
			@path = path
			@display_path = display_path
			@tests = tests
			@keys = keys
			@whole = indices.size == tests.size
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

		# Whether every one of its tests was selected to run.
		def whole? = @whole

		# Set when loading this file crashed a worker, so no other worker tries.
		attr_accessor :unstealable

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

	# A loader process, the pipe to send it commands, the pipe it reports on
	# once booted (see Loader#initialize), and its unused channels. `group` is
	# the group whose tests its workers run, or nil for tests in none. Without
	# fork, the loader is a thread, with no pid, commands or report.
	class LoaderProcess
		def initialize(group:, pid:, control:, report:, channels:)
			@group = group
			@pid = pid
			@control = control
			@report = report
			@spares = channels.each_with_index.map { |channel, index| [index, channel] }
			@status = nil
		end

		attr_reader :group, :pid, :report, :spares

		# The report, or nil if the loader exited without one.
		def read_report
			header = @report.read(4)
			data = @report.read(header.unpack1("N")) if header&.bytesize == 4
			Marshal.load(data) if data
		ensure
			close_report
		end

		# Returns nil, for a report that never came.
		def close_report
			@report&.close
			@report = nil
		end

		# Returns false if it can't, e.g. because the loader has exited.
		def command(line)
			return false unless @control

			@control.puts(line)
			true
		rescue Errno::EPIPE
			@control.close
			@control = nil
			false
		end

		# Once closed, the loader starts no more workers, and exits once its workers have.
		def close
			@control&.close
			@control = nil
			close_report
			@spares.each { |_index, channel| channel.close }
			@spares.clear
		end

		# Its exit status once it has exited, or nil.
		def status
			@status ||= Process.wait2(@pid, Process::WNOHANG)&.last if @pid
		end

		def wait
			@status ||= Process.wait2(@pid).last if @pid
		end

		def kill
			Process.kill("KILL", @pid) if @pid && !status
		rescue Errno::ESRCH
			nil
		end
	end

	class Worker
		# `slot` is the worker's QUICKDRAW_WORKER number, which a worker started in
		# its place inherits. `process` numbers every worker process in the run, for
		# history. `loader` is the LoaderProcess it forked from.
		def initialize(channel, slot, process, loader)
			@channel = channel
			@slot = slot
			@process = process
			@loader = loader
			@loaded = {}
			@loading = nil
			@batch = nil
			@started = false
			@idle = false
			@pid = nil
			@sequence = 0
			@timeout = nil
			@last_message_at = now
		end

		attr_reader :channel, :slot, :process, :loader, :loaded, :last_message_at

		def group = @loader.group
		attr_accessor :loading, :batch, :started, :idle, :pid

		# [seconds, thread backtraces] once the worker reports a test timed out.
		attr_accessor :timeout

		def received_message
			@last_message_at = now
		end

		def silent_for
			now - @last_message_at
		end

		private def now
			Process.clock_gettime(Process::CLOCK_MONOTONIC)
		end

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
	def initialize(
		files:, processes:, cores:, max_processes:, seed:, reporter:,
		filter: Quickdraw::Filter.new, fail_fast: false, test_output_to_stderr: false, selection: "", history_path: nil, only_keys: nil, whole_files: {}, profile: false, coverage: false
	)
		@seed = seed
		@processes = processes
		@cores = cores
		@max_processes = max_processes
		@filter = filter
		@fail_fast = fail_fast
		@stopping = false
		@interrupted = false
		@abandoned = []
		@selected = 0
		@outcome = Quickdraw::Outcome.new
		@selection = selection
		@reporter = reporter
		@history_path = history_path
		@only_keys = only_keys
		@whole_files = whole_files
		@test_output_to_stderr = test_output_to_stderr
		@profile = profile
		@coverage = Quickdraw::CoverageReport.new if coverage
		# Each test file's source files that ran, with --coverage.
		@coverage_map = {}
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
		@forking = Process.respond_to?(:fork)
		@test_files = @unloaded.map(&:first)
		@workers = {}
		@process_count = 0
		@leaving = {}
		@group_of = {}
		@gemfiles = {}

		# First, so it opens while config boots.
		@history = Quickdraw::HistoryProcess.new(@history_path) if @history_path

		# Keyed by group, nil for tests in none. This loader reports the groups
		# config defines; the others start once it has.
		@loaders = { nil => start_loader(nil) }

		# The first Ctrl-C stops the run and reports what finished; a second gives up.
		interrupt_reader, interrupt_writer = IO.pipe
		previous_handler = trap("INT") do
			exit(130) if @interrupted

			@interrupted = true
			interrupt_writer.write_nonblock(".", exception: false)
		end

		# Group loaders fork from this process, so they start before run history
		# (sqlite3) loads, once the first loader says which groups there are.
		report = @forking ? first_report(interrupt_reader) : [:booted, [], nil]
		groups = case report
		in [:booted, groups, *] then groups
		else []
		end
		groups_reported(groups) unless @interrupted

		load_plan
		@processes, @worker_choice = @forking ? choose_processes([@loaders[nil].spares.size - SPARE_CHANNELS, 1].max) : [1, "default"]
		@free_slots = Array.new(@processes) { |slot| slot }

		@reporter.start(processes: @processes, worker_choice: @worker_choice, seed: @seed, estimate:)
		reporting_started_at = now

		unless @interrupted
			reported(@loaders[nil], report)
			start_workers
		end

		checked_at = now

		until @workers.empty? && @leaving.empty? && @loaders.each_value.none?(&:report)
			reports = @loaders.each_value.filter_map(&:report)
			readable, = IO.select([*@workers.keys, *@leaving.keys, *reports, interrupt_reader], nil, nil, LIVENESS_INTERVAL)

			if @interrupted
				abandon_workers
				break
			end

			readable&.each do |io|
				if (worker = @workers[io])
					handle(worker, worker.channel.read)
				elsif @leaving.key?(io)
					# Its pipe closing means it has exited.
					case @leaving[io].first.channel.read
					in [:coverage, coverage] then @coverage.add(coverage)
					in nil then left(io)
					else nil
					end
				elsif (loader = @loaders.each_value.find { |it| it.report.equal?(io) })
					reported(loader, loader.read_report)
				end
			end

			# On a timer rather than only when nothing is readable, so a busy run
			# can't starve it.
			if now - checked_at >= LIVENESS_INTERVAL
				check_liveness
				checked_at = now
			end

			dispatch
			@reporter.tick
		end

		# No more workers will start, so loaders can exit once their workers have.
		@loaders.each_value(&:close)

		wait_for_loaders(interrupt_reader)
		wait_for_teardown if @interrupted
		processes_failed = !@interrupted && @loaders.each_value.any? { |loader| loader.pid && !loader.status&.success? }

		@outcome.interrupted = @interrupted
		@outcome.coverage = @coverage
		@outcome.not_run = @files.each_value.sum { |file| file.pending.size }
		@outcome.unloaded_files = @unloaded.size
		@outcome.processes_failed = processes_failed
		@outcome.stopped_early = @stopping
		# A filter that matches nothing is more likely a typo than a pass.
		@outcome.nothing_matched = @filter.any? && @selected.zero? && @unloaded.empty?
		@outcome.duration = now - reporting_started_at
		# Before the report, which says where it is.
		@coverage&.write
		@reporter.finish(@outcome)

		# Written after the report, so it never delays the results.
		save_history(started_at, @outcome.passed?)
		@outcome
	ensure
		trap("INT", previous_handler || "DEFAULT") if interrupt_reader
		interrupt_reader&.close
		interrupt_writer&.close
	end

	# Results already sent are kept. Tests still running are counted as not run,
	# and files still loading as not loaded.
	private def abandon_workers
		@stopping = true
		@workers.values.each { |worker| drain(worker) }
		@workers.values.each { |worker| abandon(worker) }
		@leaving.each_value { |worker, _loader| worker.channel.close }
		@leaving.clear
	end

	private def abandon(worker)
		@workers.delete(worker.channel.reader)
		worker.channel.close
		@abandoned << worker.pid if worker.pid

		if (path = worker.loading)
			@unloaded.unshift([path, display_path(path)]) unless @files.key?(path)
		elsif (batch = worker.batch)
			file, indices = batch
			file.pending.unshift(*indices)
		end
	end

	# Forks a loader for `group`, with a channel for every worker it could run,
	# plus spares for replacing workers that crash. The loader for tests in no
	# group starts first, before the worker count is chosen, and reports groups.
	private def start_loader(group)
		capacity = @forking ? channel_capacity((@processes || @max_processes) + SPARE_CHANNELS) : 1
		coordinator_channels, worker_channels = Array.new(capacity) { Quickdraw::Channel.pair }.transpose

		unless @forking
			Quickdraw::Loader.new(worker_channels, @test_files, @seed, profile: @profile).call_in_thread
			return LoaderProcess.new(group:, pid: nil, control: nil, report: nil, channels: coordinator_channels)
		end

		control, control_writer = IO.pipe
		report, report_writer = IO.pipe

		pid = Quickdraw::Loader.start(
			worker_channels, @test_files, @seed,
			gemfile: @gemfiles[group],
			control:, test_output_to_stderr: @test_output_to_stderr, profile: @profile, coverage: !@coverage.nil?, group:, report: report_writer,
		) do
			coordinator_channels.each(&:close)
			control_writer.close
			report.close
			# Or a process this loader starts could keep the others' pipes open.
			@loaders&.each_value(&:close)
			@history&.disconnect
		end

		worker_channels.each(&:close)
		control.close
		report_writer.close

		LoaderProcess.new(group:, pid:, control: control_writer, report:, channels: coordinator_channels)
	end

	# Once a loader has booted, or failed to (see Loader#initialize). The first
	# loader's report says which groups there are. Without a report, the loader
	# exited while booting.
	private def reported(loader, report)
		error = case report
		in [:booted, _groups, coverage]
			if coverage
				# What booting covered, which its workers don't repeat.
				@coverage.add(coverage)
				(@coverage_map[Quickdraw::History::BOOT] ||= {}).merge!(Quickdraw::CoverageCollector.run(coverage).to_h { |source| [source, true] })
			end

			return
		in [:failed, error]
			error
		in nil
			{ "name" => "Quickdraw::LoaderCrashed", "message" => "The process that loads config exited while booting.", "backtrace" => [] }
		end

		# Without config, which groups there are isn't known, so every file is in
		# the first loader's, and fails.
		message = loader.group ? "The #{loader.group} group’s setup failed: #{error['message']}" : error["message"]
		failure = error.merge("message" => message)

		@unloaded.select { |_path, display_path| @group_of[display_path] == loader.group }.each do |entry|
			@unloaded.delete(entry)
			load_failed(entry.first, failure)
		end

		# Its workers will never start, so their slots can go to other groups.
		@workers.values.select { |worker| worker.loader.equal?(loader) }.each { |worker| crashed(worker) }
	end

	# The first loader's report, or nil if it exited without one or Ctrl-C was
	# pressed while it booted.
	private def first_report(interrupt_reader)
		loader = @loaders[nil]

		until @interrupted
			readable, = IO.select([loader.report, interrupt_reader], nil, nil, LIVENESS_INTERVAL)
			return loader.read_report if readable&.include?(loader.report)
			# A process config started can hold the pipe open after the loader exits.
			return loader.close_report if loader.status
		end
	end

	# Starts a loader for each group with tests to run.
	private def groups_reported(groups)
		@gemfiles = groups.to_h { |name, _patterns, gemfile| [name, gemfile] }
		@group_of = @display_paths.to_h do |_path, display_path|
			name, = groups.find { |_name, patterns| patterns.any? { |pattern| File.fnmatch?(pattern, display_path, File::FNM_PATHNAME | File::FNM_EXTGLOB) } }
			[display_path, name]
		end

		(@group_of.values.uniq - [nil]).each { |group| @loaders[group] = start_loader(group) }
	end

	# Shares workers out between loaders by how many files each has to run.
	private def start_workers
		files = @unloaded.map { |_path, display_path| @group_of[display_path] }.tally

		allocate(files, @processes).each do |group, workers|
			workers.times { start_worker(@loaders.fetch(group), @free_slots.shift) }
		end
	end

	# One worker for each group, as far as they go, biggest first, then the
	# rest one at a time to whichever has the most files per worker.
	private def allocate(files, workers)
		allocation = files.transform_values { 0 }
		ranked = files.sort_by { |_group, count| -count }.map(&:first)
		return allocation if ranked.empty?

		ranked.first(workers).each { |group| allocation[group] = 1 }
		(workers - allocation.values.sum).times do
			group = ranked.max_by { |name| files[name].fdiv(allocation[name] + 1) }
			allocation[group] += 1
		end

		allocation
	end

	# Returns whether it started.
	private def start_worker(loader, slot)
		return false unless slot

		index, channel = loader.spares.shift
		if channel && (!@forking || loader.command("fork #{index} #{slot}"))
			@workers[channel.reader] = Worker.new(channel, slot, @process_count += 1, loader)
			true
		else
			channel&.close
			@free_slots << slot
			false
		end
	end

	# Interruptible, since a loader can be slow to exit (an at_exit hook, say).
	private def wait_for_loaders(interrupt_reader)
		until @interrupted || @loaders.each_value.all? { |loader| loader.pid.nil? || loader.status }
			interrupt_reader.wait_readable(0.01)
		end
	end

	# Ctrl-C reached the workers too, so they're running teardown. Waits a little
	# for them, so their output comes before the summary, then stops whatever is
	# left.
	private def wait_for_teardown
		deadline = now + INTERRUPT_GRACE
		sleep 0.01 until (done = @loaders.each_value.all? { |loader| loader.pid.nil? || loader.status }) || now > deadline
		return if done

		@abandoned.each do |pid|
			Process.kill("KILL", pid)
		rescue Errno::ESRCH
			nil
		end

		@loaders.each_value(&:kill)
		@loaders.each_value(&:wait)
	end

	# The last run of this selection's plan (see History::Plan).
	# Timings from history (see History::Plan), and this selection's runs.
	private def load_plan
		return unless @history_path

		@plan = Quickdraw::History.plan(@history_path) or return
		@runs = @plan.selections[@selection]
		@averages = @plan.averages
		order_slowest_files_first(@plan.files.transform_values { |_count, total, _longest| total })
	end

	# From the last run of the same selection. --failed runs a different subset each time.
	private def estimate
		return if @only_keys || !@runs&.last_run

		Quickdraw::Reporters::Estimate.new(tests: @runs.last_run.tests, duration: @runs.last_run.duration)
	end

	# Returns [count, how it was chosen].
	private def choose_processes(capacity)
		return [@processes.clamp(1, capacity), "manual"] if @processes
		return [@cores.clamp(1, capacity), "default"] unless @history_path

		choice = Quickdraw::WorkerTuner.new(cores: @cores, max: capacity).choose(
			# --failed runs a different subset each time, so its timings aren't comparable.
			runs: (@only_keys || !@runs) ? [] : @runs.recent_runs,
			expected: @plan&.expected(@unloaded.map(&:last)) || Quickdraw::History::Expected.new(test_time: 0.0, tests: 0, longest_test: nil),
			waiting_share: @runs&.waiting_share,
		)

		[choice.processes, choice.reason]
	end

	# Workers that died without closing their pipes, because a process they or
	# the loader forked still holds them open. Workers that haven't reported a
	# pid yet are only known dead if the loader has died too.
	private def check_liveness
		# A loader that exited may not have reported, and a process its config
		# started can hold the report's pipe open.
		@loaders.each_value do |loader|
			next unless loader.report && loader.status

			reported(loader, loader.report.wait_readable(0) ? loader.read_report : loader.close_report)
		end

		# A process a worker started can hold its pipe open after it exits.
		@leaving.to_a.each do |reader, (worker, _loader)|
			next unless worker.pid ? !worker.alive? : worker.loader.status

			# Its coverage may be waiting in the pipe.
			while reader.wait_readable(0) && (message = worker.channel.read)
				@coverage.add(message.last) if message.first == :coverage
			end

			left(reader)
		end

		@workers.values.each do |worker|
			dead = worker.pid ? !worker.alive? : worker.loader.status
			next unless dead || overdue?(worker)

			# Messages it sent before dying (results, a timeout report) or that this
			# process hadn't read yet. Handling them may settle the question.
			drain(worker)
			next unless @workers.key?(worker.channel.reader)

			if dead
				crashed(worker)
			elsif overdue?(worker)
				kill(worker)
			end
		end
	end

	# Whether the worker has been silent well past its running test's timeout:
	# the watchdog should have caught that, so something (C code holding the GVL,
	# say) stopped it running. Or it reported a timeout and hasn't exited.
	private def overdue?(worker)
		return false unless worker.pid && worker.started
		return worker.silent_for > TIMEOUT_GRACE if worker.timeout

		file, (index, *) = worker.batch
		timeout = index && file.tests[index]["timeout"]
		!!timeout && worker.silent_for > timeout + TIMEOUT_GRACE
	end

	private def drain(worker)
		reader = worker.channel.reader

		while @workers.key?(reader) && reader.wait_readable(0)
			handle(worker, worker.channel.read)
		end
	end

	private def kill(worker)
		file, (index, *) = worker.batch
		worker.timeout ||= [file.tests[index]["timeout"], []]
		Process.kill("KILL", worker.pid)
	rescue Errno::ESRCH
		nil
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end

	# The test thread's backtrace is the error's. Other threads go in the details,
	# since a hang is often waiting on one of them.
	private def timeout_error(seconds, threads)
		test_thread, *others = threads

		details = others.map do |thread|
			"Thread #{thread['name']}:\n#{thread['backtrace'].first(10).map { |frame| "  #{frame}" }.join("\n")}"
		end

		{
			"name" => "Quickdraw::Timeout",
			"message" => "The test took longer than its #{seconds}s timeout.",
			"backtrace" => test_thread&.fetch("backtrace") || [],
			"details" => (details.join("\n\n") if details.any?),
		}
	end

	# Starts a worker in the crashed worker's slot, so it takes over that slot's
	# resources, if its group has work left. A crashing test is reported once
	# and not rerun, so this can't loop.
	private def replace(worker)
		if @stopping || worker.loader.status || !work_left?(worker.group)
			@free_slots << worker.slot
		else
			start_worker(worker.loader, worker.slot)
		end
	end

	private def work_left?(group)
		@unloaded.any? { |_path, display_path| @group_of[display_path] == group } ||
			@files.each_value.any? { |file| file.pending.any? && @group_of[file.display_path] == group }
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

	# { test path => [source paths, whether every test in the file ran] }. A
	# file that only ran some tests may not have run all its sources.
	private def coverage_map
		whole = @files.each_value.to_h { |file| [file.display_path, file.whole? && file.pending.empty?] }
		whole[Quickdraw::History::BOOT] = true
		@coverage_map.to_h { |path, sources| [path, [sources.keys, whole.fetch(path, false)]] }
	end

	# A partial run would mislead worker tuning, so an interrupted one isn't saved.
	private def save_history(started_at, passed)
		return if !@history || @interrupted

		run = {
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
		}

		@history.save(run, (coverage_map if @coverage))
	rescue Quickdraw::History::Error => error
		warn "Quickdraw couldn’t save this run to its history (#{error.message})."
	ensure
		@history&.close
	end

	# Files with no history go first, since they could be slow too. The rest go
	# slowest first, so the longest files don't start last.
	private def order_slowest_files_first(durations)
		@unloaded = @unloaded.each_with_index.sort_by do |(_absolute, display), index|
			duration = durations.fetch(display, 0.0)
			(duration > 0) ? [1, -duration, index] : [0, 0, index]
		end.map(&:first)
	end

	private def handle(worker, message)
		worker.received_message

		case message
		in nil
			crashed(worker)
		in [:timeout, seconds, threads]
			# The worker exits next; crashed reports it.
			worker.timeout = [seconds, threads]
		in [:pid, pid]
			worker.pid = pid
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
		in [:covered, path, sources]
			(@coverage_map[display_path(path)] ||= {}).merge!(sources.to_h { |source| [source, true] })
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
			keys = (Quickdraw::History.keys(display_path, tests) if @history)
			indices = @filter.selected_indices(path, tests)

			@filter.unmatched_lines(path, tests).each do |line|
				warn "No test starts at or above #{display_path}:#{line}."
			end

			if @only_keys && !@whole_files.key?(display_path)
				indices.select! { |index| @only_keys.key?(keys[index]) }
			end

			@selected += indices.size

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
		@outcome.record(result)
		@reporter.result(file.display_path, file.tests[index], result)
		@stopping = true if @fail_fast && (result["failures"].any? || result["errors"].any?)

		if @history
			@records << Quickdraw::History::Record.new(
				key: file.keys[index],
				path: file.display_path,
				test: file.tests[index],
				result:,
				worker: worker.process,
				slot: worker.slot,
				sequence: worker.next_sequence,
			)
		end
	end

	private def load_failed(path, error)
		display_path = display_path(path)
		@outcome.load_failed
		@reporter.load_failed(display_path, error)
		@load_errors << [display_path, error]
		@stopping = true if @fail_fast
	end

	private def crashed(worker)
		# After Ctrl-C, a worker exiting is expected, and its test didn't finish.
		return abandon(worker) if @interrupted

		@workers.delete(worker.channel.reader)
		worker.channel.close

		crash = if (timeout = worker.timeout)
			timeout_error(*timeout)
		else
			{
				"name" => "Quickdraw::WorkerCrashed",
				"message" => "The worker process exited unexpectedly.",
				"backtrace" => [],
			}
		end

		if (path = worker.loading)
			if (file = @files[path])
				# It loaded elsewhere but crashed this worker, so don't let it take more.
				file.unstealable = true
			else
				load_failed(path, crash)
			end
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

		replace(worker)
	end

	private def dispatch
		idle = @workers.each_value.select(&:idle)
		all_idle = idle.size == @workers.size

		# With --fail-fast, batches already running finish, but nothing new starts.
		idle = [] if @stopping

		# Slots freed by crashes, or by a group that failed to boot, go where the work is.
		until @stopping || @free_slots.empty? || !(loader = busiest_loader)
			start_worker(loader, @free_slots.shift)
		end

		idle.each do |worker|
			if (file = own_file(worker))
				run_batch(worker, file)
			elsif (path = next_unloaded(worker.group))
				load(worker, path)
			elsif (file = file_to_steal(worker, all_idle))
				load(worker, file.path)
			elsif (loader = busiest_loader(except: worker.loader))
				move(worker, loader)
			end
		end

		return unless all_idle && @workers.each_value.all?(&:idle)

		# Not done until they exit, after sending their coverage.
		@workers.each_value do |worker|
			worker.channel.write([:stop])
			@leaving[worker.channel.reader] = [worker, nil]
		end

		@workers.clear
	end

	# The slowest unloaded file in `group` (see #order_slowest_files_first).
	private def next_unloaded(group)
		index = @unloaded.index { |_path, display_path| @group_of[display_path] == group } or return
		@unloaded.delete_at(index).first
	end

	# The loader, other than `except`, whose group has the most work left per
	# worker, so workers stay busy across groups.
	private def busiest_loader(except: nil)
		candidates = @loaders.each_value.reject do |loader|
			loader.equal?(except) || loader.spares.empty? || loader.status || !work_left?(loader.group)
		end

		candidates.max_by do |loader|
			workers = @workers.each_value.count { |other| other.loader.equal?(loader) }
			remaining_tests(loader.group).fdiv(workers + 1)
		end
	end

	# Tests not yet run in loaded files, plus one for each file not yet loaded.
	private def remaining_tests(group)
		@unloaded.count { |_path, display_path| @group_of[display_path] == group } +
			@files.each_value.sum { |file| (@group_of[file.display_path] == group) ? file.pending.size : 0 }
	end

	# Stops the worker, and once it has exited (see #left), starts one in its
	# slot in `loader`. Not before, since its at_exit hooks may still be using
	# the slot's resources, such as a database.
	private def move(worker, loader)
		worker.channel.write([:stop])
		@workers.delete(worker.channel.reader)
		@leaving[worker.channel.reader] = [worker, loader]
	end

	# `loader` is where the worker was moving to, or nil at the end of the run.
	private def left(reader)
		worker, loader = @leaving.delete(reader)
		worker.channel.close

		if loader && work_left?(loader.group)
			start_worker(loader, worker.slot)
		else
			@free_slots << worker.slot
		end
	end

	private def own_file(worker)
		worker.loaded
			.filter_map { |path, loaded| @files.fetch(path) if loaded }
			.select { |file| file.pending.any? }
			.max_by { |file| file.pending.size }
	end

	# When every worker is idle, nothing else will pick up the work, so steal regardless of cost.
	private def file_to_steal(worker, all_idle)
		candidates = @files.each_value.reject do |file|
			file.unstealable || worker.loaded.key?(file.path) || file.pending.empty? || @group_of[file.display_path] != worker.group
		end

		unless all_idle
			candidates.select! do |file|
				# Nobody else will run tests left behind by a crashed worker.
				next true if orphaned?(file)

				estimate = file.estimated_pending_time
				estimate && estimate > file.load_duration * 2
			end
		end

		candidates.max_by { |file| file.estimated_pending_time || 0 }
	end

	private def orphaned?(file)
		@workers.each_value.none? { |worker| worker.loaded[file.path] }
	end

	private def run_batch(worker, file)
		# A worker runs its whole batch, so with --fail-fast, one test at a time
		# stops promptly after a problem.
		indices = @fail_fast ? file.pending.shift(1) : file.next_batch
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
