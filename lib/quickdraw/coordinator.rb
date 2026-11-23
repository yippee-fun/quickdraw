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
	autoload :Retries, "quickdraw/coordinator/retries"
	autoload :Scheduler, "quickdraw/coordinator/scheduler"
	autoload :Flakes, "quickdraw/coordinator/flakes"

	BATCH_BUDGET = 0.02

	# Channels kept for replacing workers that crash.
	SPARE_CHANNELS = 4

	# How often to check for workers that died without closing their pipes, or
	# whose tests are stuck where the watchdog can't stop them, in seconds.
	LIVENESS_INTERVAL = 1

	# How long the coordinator waits for a message before checking on workers anyway.
	POLL_INTERVAL = 0.1
	# How long past a test's timeout to wait for its watchdog before killing it.
	TIMEOUT_GRACE = 5

	# How long to wait for teardown after Ctrl-C before reporting, in seconds.
	INTERRUPT_GRACE = 3

	class TestFile
		# A file runs once in each group it's in (see Configuration::Group), as a
		# TestFile for each. `group` is the group's name, or nil for none, and
		# `variant` its variant, or nil.
		#
		# `keys` are the tests' history keys, or nil without history. `indices` are
		# the tests to run. `prior_average` is the average test duration from
		# history, used until this run has its own measurements, and `expected`
		# each test's own, or nil where history has none.
		#
		# Tests run in a random order, except that slow ones (see #slow?) go first,
		# slowest first, so the longest work doesn't start last and leave other
		# workers waiting for it at the end. They're sorted by how many times the
		# batch budget they take, rounded down to a power of two, so the order a
		# seed gives only changes when a test gets about twice as fast or slow.
		def initialize(path:, display_path:, group:, variant:, tests:, keys:, indices:, load_duration:, prior_average:, random:, expected: nil)
			@path = path
			@display_path = display_path
			@group = group
			@variant = variant
			@tests = tests
			@keys = keys
			@whole = indices.size == tests.size
			@load_duration = load_duration
			@prior_average = prior_average
			@expected = expected || []
			@pending = indices.shuffle(random:).each_with_index.sort_by do |index, position|
				[slow?(index) ? -Math.log2(@expected[index] / BATCH_BUDGET).floor - 1 : 0, position]
			end.map(&:first)

			# With history, the first batch can fill the budget, up to a quarter of the
			# file in case its tests have got slower since.
			@batch_size = if prior_average
				(BATCH_BUDGET / [prior_average, 1e-9].max).floor.clamp(1, [@pending.size / 4, 1].max)
			else
				1
			end
			@total_duration = 0.0
			@completed = 0
			@size = indices.size
			@reported = 0
			@crashes = []
		end

		attr_reader :path, :display_path, :group, :variant, :tests, :keys, :pending, :load_duration

		# How many of its tests are selected, how many have finished at least
		# once, for scheduling, and how many have a final result, after retries.
		attr_reader :size, :completed, :reported

		def reported!
			@reported += 1
		end

		# Whether every one of its tests was selected to run.
		def whole? = @whole

		# Set when loading this file crashed a worker, so no other worker tries.
		attr_accessor :unstealable

		# A worker sends the results of tests that pass together (see
		# Worker::RESULTS_AT_ONCE), so when one crashes, the tests it has sent
		# no result for may have passed, crashed it, or not run. They run again,
		# one at a time, until the one that crashes is known. `output` is what
		# the worker printed.
		def suspect(indices, output)
			@crashes << [indices.dup, output]
		end

		# Once the test has crashed a worker alone, which explains the crash
		# it was a suspect of, if any.
		def crash_found(index)
			@crashes.reject! { |indices, _output| indices.include?(index) }
		end

		# Once the test has run without crashing a worker. If it was the last
		# suspect of a crash, yields what the crashed worker printed.
		def cleared(index)
			@crashes.reject! do |indices, output|
				next false unless indices.delete(index) && indices.empty?

				yield output
				true
			end
		end

		def next_batch
			# Alone, so other workers can take the slow tests after it.
			return @pending.shift(1) if @crashes.any? || slow?(@pending.first)

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

		# From history, scaled by how this run's tests compare with it so far.
		def estimated_pending_time
			average = average_duration
			return unless average || @pending.any? { |index| @expected[index] }

			drift = (@completed > 0 && @prior_average&.positive?) ? average / @prior_average : 1.0
			@pending.sum { |index| @expected[index] ? @expected[index] * drift : average || 0.0 }
		end

		# The tests waiting that are slow (see #slow?).
		def slow_pending
			@pending.take_while { |index| slow?(index) }.size
		end

		# How long the next test is expected to take, from history, or nil.
		def next_expected
			@expected[@pending.first] if @pending.any?
		end

		# A test that takes a batch's budget on its own.
		def slow?(index)
			(expected = @expected[index]) && expected >= BATCH_BUDGET
		end
	end

	# A loader process, the pipe to send it commands, the pipe it reports on
	# once booted (see Loader#initialize), and its channels. `group` is the
	# group whose tests its workers run, or nil for tests in none. Without
	# fork, the loader is a thread, with no pid or commands.
	#
	# `channels` are those the loader has too. It can have `capacity` in all:
	# the rest are named pipes, made in `directory` as they're taken, which the
	# loader opens (see Loader#open_channel).
	class LoaderProcess
		def initialize(group:, pid:, control:, report:, channels:, capacity: channels.size, directory: nil)
			@group = group
			@pid = pid
			@control = control
			@report = report
			@channels = channels
			@capacity = capacity
			@directory = directory
			@taken = 0
			@status = nil
		end

		attr_reader :group, :pid, :report

		# How many more channels it has to take.
		def spares = @capacity - @taken

		# A channel no worker has had, and its number for the loader, or nil
		# when none is left.
		def take_channel
			return if spares.zero?

			channel = @channels[@taken] || named_channel(@taken) or return
			@taken += 1
			[@taken - 1, channel]
		end

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

		# A run's flakes as JSON (see Flake.report), for config's on_flaky callbacks.
		def send_flakes(json)
			command("flakes #{json.bytesize}") && @control.write(json)
		rescue Errno::EPIPE
			@control.close
			@control = nil
		end

		# Once closed, the loader starts no more workers, and exits once its workers have.
		def close
			@control&.close
			@control = nil
			close_report
			@channels.drop(@taken).each(&:close)
			@capacity = @taken
			Quickdraw.remove_tree(@directory) if @temporary == Process.pid
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

		# Without somewhere to make it, or file descriptors for it, there are
		# no more channels.
		private def named_channel(index)
			unless Dir.exist?(@directory)
				Dir.mkdir(@directory, 0o700)
				@temporary = Process.pid
			end

			up = fifo("#{index}.up", File::RDONLY | File::NONBLOCK)
			# Opened for reading too, so it doesn't wait for the loader, which
			# sees the end once this process closes it.
			Quickdraw::Channel.new(up, fifo("#{index}.down", File::RDWR))
		rescue SystemCallError => error
			up&.close
			@capacity = @taken
			warn "Quickdraw couldn’t open a pipe for another worker (#{error.message})."
			nil
		end

		private def fifo(name, flags)
			path = File.join(@directory, name)
			File.mkfifo(path, 0o600)
			File.open(path, flags, binmode: true)
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
			@ready = false
			@idle = false
			@pid = nil
			@sequence = 0
			@timeout = nil
			@fresh = true
			@retrying = nil
			@queued_retries = []
			@last_message_at = now
		end

		attr_reader :channel, :slot, :process, :loader, :last_message_at

		# The files it has loaded, by path: each one's TestFile, in its group, or
		# false if loading it raised.
		attr_reader :loaded

		def group = @loader.group
		attr_accessor :loading, :batch, :started, :idle, :pid

		# Whether it has said it's ready, once after starting.
		attr_accessor :ready

		# Whether it has yet to run a test, so it can retry one.
		attr_accessor :fresh

		# The Retry it's loading a file for, or running.
		attr_accessor :retrying

		# Retries of tests that failed in it, to run in it once its batch ends.
		attr_reader :queued_retries

		# [seconds, thread backtraces] once the worker reports a test timed out.
		attr_accessor :timeout

		# The file the worker captures tests' output in (see Capture), if it does.
		attr_accessor :output_path

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

	# `processes` is nil to choose the worker count automatically, from the
	# machine's cores up to `max_processes`. `selection` identifies what was
	# asked for, so runs of the same selection can be compared. `history_path` is nil to run without
	# history. `only_keys` limits each file to the tests with those history keys
	# (a Hash keyed by key), except files in `whole_files`, which run in full.
	# `capture` and `leaks` are for workers (see Worker#initialize). A selection
	# that isn't `repeatable` (such as --changed) picks different tests from run
	# to run, so it isn't compared with the last. In watch mode, `warm_loaders`
	# are loaders that stay booted between runs. With `timeline`, it records
	# how workers spent the run (see Timeline). With `elastic`, a count that
	# wasn't given grows while tests leave CPU idle (see Elastic). Flaky tests
	# go to config's on_flaky callbacks, and to `flakes_path` as JSON. With
	# `quarantine`, tests flaky in recent runs can fail without failing the run.
	# With `variants`, files run in just the groups with those variants, of
	# those with one (see Configuration::Group). `browser_tests` is :only for
	# just browser groups' files, :all for every file, or :default to leave
	# them out unless `named_files` (expanded paths) has them, `variants` were
	# asked for, or config's by_default includes them.
	#
	# Run settings config can set too (`capture`, `leaks`, `retries`,
	# `allow_flaky`, `quarantine`, `flakes_path`, `elastic` and `processes`)
	# are nil unless the command line gave them, and config's apply then (see
	# #apply_settings).
	def initialize(
		files:, processes:, max_processes:, seed:, reporter:,
		filter: Quickdraw::Filter.new, fail_fast: false, test_output_to_stderr: false, selection: "", repeatable: true, history_path: nil, only_keys: nil, whole_files: {}, profile: false, coverage: false,
		capture: nil, capture_loading: false, leaks: nil, retries: nil, allow_flaky: nil, quarantine: nil, flakes_path: nil, output_paths: [], warm_loaders: nil, timeline: false, elastic: nil, variants: nil,
		browser_tests: :default, named_files: {}
	)
		raise ArgumentError, "browser_tests must be :default, :only or :all, not #{browser_tests.inspect}." unless browser_tests in :default | :only | :all

		@variant_filter = variants
		@browser_tests = browser_tests
		@named_files = named_files
		@timeline = Quickdraw::Timeline.new if timeline
		@elastic_allowed = elastic
		@warm_loaders = warm_loaders
		@repeatable = repeatable
		@retry_count = retries
		@allow_flaky = allow_flaky
		@quarantine = quarantine
		@flakes_path = flakes_path
		# Reports' files, which config's flakes path mustn't be.
		@output_paths = output_paths
		@flakes = Flakes.new(seed:, path: flakes_path, quarantined: nil)
		# Workers waiting for the terminal, and the one in a debugger.
		@debug_queue = []
		@debugger = nil
		@outcome = Quickdraw::Outcome.new
		@capture = capture
		@capture_loading = capture_loading
		@leaks = leaks
		@seed = seed
		@processes = processes
		@max_processes = max_processes
		@filter = filter
		@fail_fast = fail_fast
		@stopping = false
		@interrupted = false
		@abandoned = []
		@abandoned_output_paths = []
		@selected = 0
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
		@display_paths = files.shuffle(random: Random.new(seed)).to_h do |path|
			absolute = File.expand_path(path)
			[absolute, absolute.delete_prefix("#{Dir.pwd}/")]
		end
		# Files to load, as [path, display path, group], once for each group a
		# file is in (see #groups_reported).
		@unloaded = @display_paths.map { |path, display_path| [path, display_path, nil] }
		# TestFiles by [path, group].
		@files = {}
		# Each group's variant, by name (see Configuration::Group).
		@variants = {}
		@lines_checked = {}
		# Display paths of files that didn't load, or run, in every group they're in.
		@partly_run = {}
		# Whether --browser asked for a browser config doesn't have, or `qd
		# browser` for browser tests when config has none.
		@refused = false
		# Whether every group config defines booted, for the coverage map.
		@every_group_booted = false
		# Files with slow tests waiting (see TestFile#slow?), so dispatching doesn't scan the rest.
		@slow_files = {}
		@averages = {}
		@load_errors = []
	end

	def call
		started_at = Time.now
		@reporter.booting
		@forking = Process.respond_to?(:fork)
		@test_files = @display_paths.keys
		@workers = {}
		# The workers with nothing to do, so dispatching can tell when there are none.
		@idle = {}
		@process_count = 0
		@leaving = {}
		@gemfiles = {}

		# First, so it opens while config boots.
		@history = Quickdraw::HistoryProcess.new(@history_path) if @history_path
		# A retry needs a fresh worker, which needs fork.
		# Channels for retries open before config is read, so for as many as it could ask for.
		@retries = Retries.new(@forking ? (@retry_count || Quickdraw::Configuration::MOST_RETRIES) : 0, fail_fast: @fail_fast, in_history: !@history.nil?)

		# Keyed by group, nil for tests in none. This loader reports the groups
		# config defines; the others start once it has.
		@loaders = { nil => start_loader(nil) }

		# The first Ctrl-C stops the run and reports what finished; a second gives up.
		interrupt_reader, interrupt_writer = IO.pipe
		previous_handler = trap("INT") do
			# Ctrl-C in a debugger is the debugger's.
			next if @debugger

			exit(130) if @interrupted

			@interrupted = true
			interrupt_writer.write_nonblock(".", exception: false)
		end

		# Group loaders fork from this process, so they start before run history
		# (sqlite3) loads, once the first loader says which groups there are.
		report = first_report(interrupt_reader)
		groups, settings = case report
		in [:booted, groups, _coverage, settings] then [groups, settings]
		else [[], {}]
		end
		# Before the group loaders start, so they get what config set too.
		apply_settings(settings)
		groups_reported(groups, booted: (report in [:booted, *])) unless @interrupted

		load_plan
		# Retries get the channels left over, so a low file limit costs retries, not workers.
		@processes, @worker_choice = @forking ? choose_processes([@loaders[nil].spares - SPARE_CHANNELS, 1].max) : [1, "default"]

		# Channels for workers open before config is read, for as many as the machine has cores.
		if @configured_processes && @processes < @configured_processes
			warn "config.processes = #{@configured_processes}, but channels for only #{@processes} workers were opened before config was read. -p #{@configured_processes} opens more."
		end

		@scheduler = Scheduler.new(
			groups:, plan: @plan, core_budget: @processes,
			unloaded: @unloaded, files: @files, workers: @workers, leaving: @leaving, loaders: @loaders, retries: @retries,
		)
		# A worker costs more to start than it saves unless it has work, so the
		# run starts with as many as its files are worth (see
		# Scheduler#first_workers), and the rest of its slots are held until
		# there's work for them (see #release_slots).
		first = [@processes, @scheduler.first_workers].min
		@free_slots = Array.new(first) { |slot| slot }
		@held_slots = Array.new(@processes - first) { |index| first + index }
		@released_at = []
		# Including slots added while running, which started at @workers_added_at.
		@slot_count = @processes
		@workers_added_at = []

		@file_count = @unloaded.size
		paths = @unloaded.map { |_path, display_path, group| (variant = @variants[group]) ? "#{display_path} [#{variant}]" : display_path }
		@reporter.start(processes: @processes, worker_choice: @worker_choice, seed: @seed, paths:, estimate:, capture: !!@capture)
		reporting_started_at = now

		unless @interrupted || @refused
			reported(@loaders[nil], report)
			start_workers
			start_elastic if @elastic_allowed && @forking && @worker_choice != "manual"
		end

		checked_at = now

		until @workers.empty? && @leaving.empty? && @loaders.each_value.none?(&:report)
			reports = @loaders.each_value.filter_map(&:report)
			readable, = IO.select([*@workers.keys, *@leaving.keys, *reports, interrupt_reader], nil, nil, POLL_INTERVAL)

			if @interrupted
				abandon_workers
				break
			end

			readable&.each do |io|
				if (worker = @workers[io] || @leaving[io]&.first)
					# Handling one can retire the worker, so it's looked up for each.
					worker.channel.read_available.each do |message|
						if @workers.key?(io)
							handle(worker, message)
						elsif @leaving.key?(io)
							leaving(io, message)
						end
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
			add_workers if @elastic&.due?
		end

		# The loader for tests in no group passes them to config's on_flaky
		# callbacks before it exits. Not in watch mode, whose loaders stay booted.
		@flakes.report(@loaders[nil]) unless @warm_loaders

		# No more workers will start, so loaders can exit once their workers have.
		@loaders.each_value(&:close)

		wait_for_loaders(interrupt_reader)
		wait_for_teardown if @interrupted
		processes_failed = !@interrupted && @loaders.each_value.any? { |loader| loader.pid && !loader.status&.success? }

		# Stopped before they could be retried.
		@retries.abandon { |attempt| report_retry(attempt, attempt.failure) }

		@outcome.interrupted = @interrupted
		@outcome.refused = @refused
		@outcome.coverage = @coverage
		# An interrupted run isn't saved (see #save_history).
		@outcome.recorded = !@history.nil? && @history.recordable? && !@interrupted
		@outcome.not_run = @files.each_value.sum { |file| file.pending.size }
		@outcome.unloaded_files = @unloaded.size
		@outcome.files = @file_count
		@outcome.unfinished_files = @files.each_value.count { |file| file.pending.any? }
		@outcome.processes_failed = processes_failed
		@outcome.stopped_early = @stopping
		# A filter that matches nothing is more likely a typo than a pass.
		@outcome.nothing_matched = @filter.any? && @selected.zero? && @unloaded.empty?
		finished_at = now
		@outcome.duration = finished_at - reporting_started_at
		@outcome.workers_added = @workers_added_at.size
		@outcome.worker_time = ((@processes - @held_slots.size - @released_at.size) * @outcome.duration) + [*@released_at, *@workers_added_at].sum { |started_at| finished_at - started_at }
		# Before the report, which says where it is.
		write_coverage if @coverage
		write_timeline if @timeline
		@reporter.finish(@outcome)

		# Written after the report, so it never delays the results.
		save_history(started_at, @outcome.passed?)
		@outcome
	ensure
		@elastic&.stop
		File.delete(Quickdraw::Debugger.flag_path) if @debugger
		trap("INT", previous_handler || "DEFAULT") if interrupt_reader
		interrupt_reader&.close
		interrupt_writer&.close
	end

	# With a format other programs read, to stderr.
	private def write_coverage
		@coverage.write
	rescue SystemCallError => error
		warn "Quickdraw couldn’t write the coverage reports (#{error.message})."
	end

	private def write_timeline
		@timeline.finish

		begin
			@timeline.write
		rescue SystemCallError => error
			warn "Quickdraw couldn’t write #{Quickdraw::Timeline::PATH} (#{error.message})."
		end

		io = @test_output_to_stderr ? $stderr : $stdout
		summary = "\n#{@timeline.summary(color: io.tty? && !ENV.key?('NO_COLOR')).join("\n")}\n"
		io.print(summary)
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
		remove(worker)
		worker.channel.close
		@timeline&.exited(worker)
		@abandoned << worker.pid if worker.pid
		# The worker shows what's left of it as it exits, unless it's killed first.
		@abandoned_output_paths << worker.output_path if worker.output_path
		@retries.release(worker)

		if (attempt = worker.retrying)
			@retries.requeue(attempt)
		elsif (path = worker.loading)
			@unloaded.unshift([path, display_path(path), worker.group]) unless @files.key?([path, worker.group])
		elsif (batch = worker.batch)
			file, indices = batch
			file.pending.unshift(*indices)
		end
	end

	# Forks a loader for `group`, which can have a channel for every worker it
	# could run, plus spares for replacing workers that crash. It starts with
	# those its first workers are likely to use, since every worker inherits
	# them all (see #likely_workers), and the rest are made as they're needed
	# (see LoaderProcess). The loader for tests in no group starts first,
	# before the worker count is chosen, and reports groups. In watch mode, a
	# warm loader stands in, once there is one for `group`.
	private def start_loader(group)
		capacity = @forking ? channel_capacity((@processes || @max_processes) + spare_channels) : 1

		session = @warm_loaders&.session(
			group, gemfile: @gemfiles[group], capacity:,
			test_files: @test_files, seed: @seed, profile: @profile, coverage: !@coverage.nil?, test_output_to_stderr: @test_output_to_stderr,
			capture: @capture, capture_loading: @capture_loading, leaks: @leaks,
		)
		return session if session

		coordinator_channels, worker_channels = Array.new(@forking ? likely_workers(group).clamp(1, capacity) : 1) { Quickdraw::Channel.pair }.transpose
		report, report_writer = IO.pipe

		unless @forking
			# Without fork, tests share this process, so leaks can't be told apart.
			Quickdraw::Loader.new(worker_channels, @test_files, @seed, profile: @profile, leaks: :off, report: report_writer).call_in_thread
			return LoaderProcess.new(group:, pid: nil, control: nil, report:, channels: coordinator_channels)
		end

		control, control_writer = IO.pipe
		directory = File.join(Quickdraw.temporary_directory, "quickdraw-pipes-#{Process.pid}-#{Random.urandom(8).unpack1('H*')}")

		pid = Quickdraw::Loader.start(
			worker_channels, @test_files, @seed,
			gemfile: @gemfiles[group], directory:,
			control:, test_output_to_stderr: @test_output_to_stderr, profile: @profile, coverage: !@coverage.nil?, group:, report: report_writer,
			capture: @capture, capture_loading: @capture_loading, leaks: @leaks,
		) do
			coordinator_channels.each(&:close)
			control_writer.close
			report.close
			# Or a process this loader starts could keep the others' pipes open.
			@loaders&.each_value(&:close)
			@warm_loaders&.disconnect
			@history&.disconnect
		end

		worker_channels.each(&:close)
		control.close
		report_writer.close

		LoaderProcess.new(group:, pid:, control: control_writer, report:, channels: coordinator_channels, capacity:, directory:)
	end

	# How many workers `group` is likely to start with: no more than it has
	# files, or than the run will have, as far as is known before config is read.
	private def likely_workers(group)
		files = @unloaded.count { |_path, _display_path, file_group| file_group == group }
		[@processes || cores, files].min
	end

	# Once a loader has booted, or failed to (see Loader#initialize). The first
	# loader's report says which groups there are. Without a report, the loader
	# exited while booting.
	private def reported(loader, report)
		error = case report
		in [:booted, _groups, coverage, *]
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

		@unloaded.select { |_path, _display_path, group| group == loader.group }.each do |entry|
			@unloaded.delete(entry)
			load_failed(entry.first, loader.group, failure)
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
	# What the command line left unset, from config's `settings` (see
	# Configuration#settings), or else the defaults. Retries are as many as
	# the channels opened for them allow (see Configuration::MOST_RETRIES).
	private def apply_settings(settings)
		@capture = settings.fetch(:capture, true) if @capture.nil?
		@capture = :loading if @capture && @capture_loading
		@retries.count = @forking ? (@retry_count || settings.fetch(:retries, 1)) : 0
		@outcome.allow_flaky = @allow_flaky.nil? ? settings.fetch(:allow_flaky, false) : @allow_flaky
		@elastic_allowed = settings.fetch(:elastic, false) if @elastic_allowed.nil?
		@configured_processes = settings[:processes] unless @processes
		@processes ||= @configured_processes
		@browser_by_default = settings.fetch(:browser_by_default, false)
		@coverage&.excluded = settings.fetch(:excluded_from_coverage, [])

		if !@forking && (@retry_count || settings[:retries])&.positive?
			warn "Retries need fork, which this platform doesn’t support, so failures aren’t retried."
		end

		if !@forking && @leaks.nil? && settings[:leaks] == :fail
			warn "config.leaks = :fail needs fork, which this platform doesn’t support, so leaks aren’t checked."
		end

		if @flakes_path.nil? && (path = settings[:flakes]&.then { |it| File.expand_path(it) })
			if @output_paths.include?(path)
				warn "config.flakes is #{path}, which a report writes too, so flakes aren’t written."
			else
				@flakes.path = path
			end
		end

		quarantine = @quarantine.nil? ? settings.fetch(:quarantine, false) : @quarantine
		@flakes.quarantined = flaky_keys if quarantine && @history_path
	end

	# { key => true } for the tests flaky in recent runs, for quarantine, or
	# none without history yet. Read in a throwaway process, since loaders
	# fork from this one and sqlite3 must not reach them. A history that can't
	# be read, such as one a CI cache restored from an older Quickdraw,
	# quarantines nothing, rather than stop the run that would rebuild it.
	private def flaky_keys
		result = Quickdraw.isolate do
			Quickdraw::History.exist?(@history_path) ? Quickdraw::History.new(@history_path, read_only: true).flaky_keys : {}
		rescue Quickdraw::History::Error => error
			error.message
		end

		case result
		in Hash then result
		in String => message
			warn "Quarantine couldn’t read the run history (#{message}), so nothing is quarantined this run."
			{}
		end
	end

	private def groups_reported(groups, booted:)
		@gemfiles = groups.to_h { |name, _patterns, gemfile| [name, gemfile] }
		@variants = groups.to_h { |name, *, variant| [name, variant] }
		browser_groups = groups.filter_map { |name, *, browser, _variant| [name, true] if browser }.to_h
		@unloaded = @unloaded.flat_map do |path, display_path|
			groups_of(display_path, groups).map { |group| [path, display_path, group] }
		end

		# Nothing runs, rather than pass without the browser asked for.
		if @variant_filter && (unknown = @variant_filter - @variants.values.compact).any?
			configured = @variants.values.compact
			warn "Quickdraw didn’t run any tests: --browser #{unknown.join(', ')} #{configured.any? ? "isn’t one of config.browser’s browsers: (#{configured.join(', ')})" : 'needs config.browser’s browsers:'}."
			@refused = true
			return
		end

		# Config that failed to boot reports no groups. Each file says why.
		return unless booted

		if @browser_tests == :only && browser_groups.empty?
			warn "Quickdraw didn’t run any tests: `#{Quickdraw::Reporters.command} browser` runs config.browser’s tests, and #{Quickdraw::Loader::CONFIG_PATH} doesn’t call config.browser."
			@refused = true
			return
		end

		left_out, @unloaded = @unloaded.partition { |path, _display_path, group| !selected?(path, browser_groups.key?(group)) }
		@outcome.browser_files_left_out = left_out.filter_map { |_path, display_path, group| display_path if browser_groups.key?(group) }.uniq.size

		# So its coverage isn't taken for the whole file's.
		running = @unloaded.to_h { |_path, display_path| [display_path, true] }
		left_out.each { |_path, display_path| @partly_run[display_path] = true if running.key?(display_path) }

		# Without fork, one loader runs every group's tests.
		@unloaded = @unloaded.map { |path, display_path| [path, display_path, nil] }.uniq unless @forking

		@unloaded.map(&:last).uniq.compact.each { |group| @loaders[group] = start_loader(group) }
		@every_group_booted = !@forking || groups.all? { |name, *| @loaders.key?(name) }
	end

	# Whether a file runs in a group, by whether it's a browser group (see
	# #initialize).
	private def selected?(path, browser)
		case @browser_tests
		in :all then true
		in :only then browser
		in :default then !browser || @browser_by_default || !@variant_filter.nil? || @named_files.key?(path)
		end
	end

	# The groups a file runs in: the first it's in, or if that has a variant,
	# each with a variant it's in, of those --browser picks. Nil for none.
	private def groups_of(display_path, groups)
		matching = groups.select { |_name, patterns| patterns.any? { |pattern| File.fnmatch?(pattern, display_path, File::FNM_PATHNAME | File::FNM_EXTGLOB) } }

		case matching
		in [] then [nil]
		in [[name, *, nil], *] then [name]
		else
			variants = matching.select { |*, variant| variant }
			picked = @variant_filter ? variants.select { |*, variant| @variant_filter.include?(variant) } : variants
			# So its coverage isn't taken for the whole file's.
			@partly_run[display_path] = true if picked.size < variants.size
			picked.map(&:first)
		end
	end

	private def start_workers
		@scheduler.allocate(@free_slots.size).each do |group, workers|
			workers.times { start_worker(@loaders.fetch(group), @free_slots.shift) }
		end
	end

	# Not where idle CPU can't be measured. A container's CPU quota limits the
	# cores, since the machine's idle CPU isn't the container's to use.
	private def start_elastic
		idle_cpu = Quickdraw::IdleCPU.start or return
		cores = [self.cores, Quickdraw::Platform.cpu_quota].compact.min
		@elastic = Quickdraw::Elastic.new(cores:, cpus: Quickdraw::Platform.cpu_cores, idle_cpu:)
	end

	# In new slots, up to the most workers a run may have, while channels are
	# left for retries and replacing crashed workers.
	private def add_workers
		return if @stopping

		wanted = @elastic.wanted(
			workers: @workers.size,
			starting: @workers.each_value.count { |worker| !worker.ready },
			busy: @workers.each_value.count { |worker| worker.ready && !worker.idle },
			waiting: waiting_tests,
		)
		# Slots held at the start come first.
		wanted -= release(wanted)
		# The tuner can choose more, from history.
		count = [wanted, @max_processes - @slot_count].min
		added = 0

		while added < count && (loader = @scheduler.busiest_loader(fitting: false)) && loader.spares > spare_channels
			start_worker(loader, @slot_count)
			@scheduler.added(loader.group)
			@slot_count += 1
			@workers_added_at << now
			added += 1
		end

		@timeline&.add(added) if added > 0
	end

	# Tests not yet started, counting each file not yet loaded as an average one.
	private def waiting_tests
		per_file = @files.empty? ? 1.0 : @files.each_value.sum { |file| file.tests.size }.fdiv(@files.size)
		@files.each_value.sum { |file| file.pending.size } + (@unloaded.size * per_file)
	end

	# Returns whether it started.
	private def start_worker(loader, slot)
		return false unless slot

		index, channel = loader.take_channel
		if channel && (!@forking || loader.command("fork #{index} #{slot}"))
			worker = Worker.new(channel, slot, @process_count += 1, loader)
			@workers[channel.reader] = worker
			@timeline&.spawned(worker)
			true
		else
			channel&.close
			@free_slots << slot
			false
		end
	end

	# Interruptible, since a loader can be slow to exit (an at_exit hook, say).
	# Checking often at first, since loaders usually exit within a few milliseconds.
	private def wait_for_loaders(interrupt_reader)
		delay = 0.0005

		until @interrupted || @loaders.each_value.all? { |loader| loader.pid.nil? || loader.status }
			interrupt_reader.wait_readable(delay)
			delay = [delay * 2, 0.01].min
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

		@abandoned_output_paths.each do |path|
			output = Quickdraw::Capture.collect(path)
			$stderr.write(output) if output
		end
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
		return if @only_keys || !@repeatable || !@runs&.last_run

		last = @runs.last_run
		Quickdraw::Reporters::Estimate.new(tests: last.tests, duration: last.duration, test_time: last.test_time)
	end

	# Asked for only when the worker count wasn't given, since finding out can
	# take a subprocess.
	private def cores
		@cores ||= Quickdraw::Platform.non_blocking_cores
	end

	# Returns [count, how it was chosen].
	private def choose_processes(capacity)
		return [@processes.clamp(1, capacity), "manual"] if @processes
		return [cores.clamp(1, capacity), "default"] unless @history_path

		choice = Quickdraw::WorkerTuner.new(cores:, max: capacity).choose(
			# --failed runs a different subset each time, so its timings aren't comparable.
			runs: (@only_keys || !@runs) ? [] : @runs.recent_runs,
			expected: @plan&.expected(@unloaded.map { |_path, display_path| display_path }.uniq) || Quickdraw::History::Expected.new(test_time: 0.0, tests: 0, longest_test: nil),
			waiting_share: @runs&.waiting_share,
		)

		[choice.processes, choice.reason]
	end

	# Workers that died without closing their pipes, because a process they or
	# the loader forked still holds them open. Workers that haven't reported a
	# pid yet are only known dead if the loader has died too.
	# Its pipe closing means it has exited.
	private def leaving(io, message)
		case message
		in [:coverage, coverage] then @coverage.add(coverage)
		in nil then left(io)
		else nil
		end
	end

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
		# Its timeout is paused while it waits for, or is in, a debugger.
		return false if @debug_queue.include?(worker) || @debugger.equal?(worker)
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
		file, (index, *rest) = worker.batch
		# With other tests it has sent no result for, which one is stuck isn't
		# known (see #crashed).
		worker.timeout ||= [file.tests[index]["timeout"], []] if rest.empty?
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
		if @stopping || worker.loader.status || !@scheduler.work_left?(worker.group)
			@free_slots << worker.slot
		else
			start_worker(worker.loader, worker.slot)
		end
	end

	private def spare_channels
		SPARE_CHANNELS + @retries.channels
	end

	# Whether the loader can start a worker for each one leaving it, plus one.
	private def spare_for?(loader)
		loader.spares > @leaving.each_value.count { |_worker, destination| destination.equal?(loader) }
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
		# A group that didn't boot may load sources the others don't.
		whole = { Quickdraw::History::BOOT => @every_group_booted }

		@files.each_value do |file|
			whole[file.display_path] = whole.fetch(file.display_path, true) && !@partly_run.key?(file.display_path) && file.whole? && file.pending.empty?
		end
		@coverage_map.to_h { |path, sources| [path, [sources.keys, whole.fetch(path, false)]] }
	end

	# A partial run would mislead worker tuning, so an interrupted one isn't saved.
	private def save_history(started_at, passed)
		return if !@history || !@history.recordable? || @interrupted

		run = {
			started_at:,
			finished_at: Time.now,
			seed: @seed,
			processes: @slot_count,
			worker_choice: @worker_choice,
			selection: @selection,
			passed:,
			loaded_paths: @files.each_value.map(&:display_path).uniq,
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
		@timeline&.received(worker, message)

		# However the worker sent them (see Worker#call), results are recorded
		# one way. Before the other messages, since most messages are results.
		if message in [:result | :integers, *]
			Quickdraw::Worker.each_result(message) { |index, result| record(worker, index, result) }
			return
		end

		case message
		in nil
			crashed(worker)
		in [:timeout, seconds, threads]
			# The worker exits next; crashed reports it.
			worker.timeout = [seconds, threads]
		in [:pid, pid]
			worker.pid = pid
		in [:capturing, path]
			worker.output_path = path
		in [:printed, output]
			@reporter.printed(output)
		in [:debugging]
			@debug_queue << worker
			give_terminal unless @debugger
		in [:debugged]
			take_terminal(worker)
		in [:ready, pid]
			worker.pid = pid
			worker.ready = true
			idle(worker)
		in [:started]
			worker.started = true
		in [:loaded, path, tests, load_duration]
			loaded(worker, path, tests, load_duration)
		in [:load_failed, path, error]
			worker.loading = nil
			worker.loaded[path] = false
			idle(worker)

			if (attempt = worker.retrying)
				worker.retrying = nil
				# Whatever the file did before it raised is still there.
				worker.fresh = false
				retried(attempt, { "failures" => [], "errors" => [error], "duration" => nil })
			elsif !@files.key?([path, worker.group])
				load_failed(path, worker.group, error)
			end
		in [:covered, path, sources]
			(@coverage_map[display_path(path)] ||= {}).merge!(sources.to_h { |source| [source, true] })
		end
	end

	private def loaded(worker, path, tests, load_duration)
		worker.loading = nil
		idle(worker)
		key = [path, worker.group]

		if (file = @files[key])
			unless file.tests == tests
				raise "#{file.display_path} defined different tests when loaded in a second worker."
			end
		else
			display_path = display_path(path)
			keys = (Quickdraw::History.keys(display_path, tests) if @history)
			indices = @filter.selected_indices(path, tests)

			# Once, though it loads in each group it's in.
			unless @lines_checked.key?(path)
				@lines_checked[path] = true

				@filter.unmatched_lines(path, tests).each do |line|
					warn "No test starts at or above #{display_path}:#{line}."
				end
			end

			if @only_keys && !@whole_files.key?(display_path)
				indices.select! { |index| @only_keys.key?(keys[index]) }
			end

			variant = @variants[worker.group]
			@selected += indices.size
			# It won't finish, since nothing in it runs.
			@reporter.nothing_to_run(display_path, variant) if indices.empty?

			expected = keys&.map { |key| @averages[key] }
			known = expected&.compact || []

			file = @files[key] = TestFile.new(
				path:,
				display_path:,
				group: worker.group,
				variant:,
				tests:,
				keys:,
				indices:,
				load_duration:,
				prior_average: (known.sum / known.size if known.any?),
				expected:,
				random: Random.new(Quickdraw.stable_hash("#{@seed}:#{display_path}")),
			)

			@slow_files[file] = true if file.slow_pending > 0
		end

		worker.loaded[path] = file
	end

	private def record(worker, index, result)
		file, indices = worker.batch
		expected = indices.shift
		raise "Expected a result for test #{expected} but got #{index}." unless expected == index

		worker.batch = nil if indices.empty?
		to_seconds(result)

		if (attempt = worker.retrying)
			worker.retrying = nil
			retried(attempt, result)
			# History doesn't record retries, so tests that ran after one couldn't
			# be bisected.
			retire(worker) if worker.queued_retries.empty?
			return
		end

		file.record(result["duration"])

		# A crash that none of the tests it could have been repeats still fails the run.
		file.cleared(index) do |output|
			@outcome.unexplained_crash = true
			@reporter.printed(output) if output && @capture_loading
		end

		@elastic&.record(result)
		placement = placement(worker)

		# Failures are retried, first in the same worker, then in fresh ones.
		return if @retries.enabled? && failed?(result) && @retries.hold(worker, file:, index:, result:, placement:, group: file.group)

		report(file, index, result, placement)
	end

	private def failed?(result)
		result["failures"].any? || result["errors"].any?
	end

	private def retried(attempt, result)
		final = @retries.retried(attempt, result, stopping: @stopping) or return
		report_retry(attempt, final)
	end

	private def report_retry(attempt, result)
		report(attempt.file, attempt.index, result, attempt.placement)
	end

	# Replaces the worker in its slot, if there's a channel for another.
	# Otherwise it carries on, rather than leave tests without a worker.
	private def retire(worker)
		move(worker, worker.loader) if spare_for?(worker.loader)
	end

	# Where a test ran, for history: [process, slot, sequence].
	private def placement(worker)
		[worker.process, worker.slot, worker.next_sequence]
	end

	ALLOCATIONS = Quickdraw::STATS.index("allocations")

	# Workers send nanosecond integers, which are much cheaper to send than floats.
	# In place, since it's for every result.
	private def to_seconds(result)
		result["duration"] /= 1e9
		stats = result["stats"]
		stats.each_index { |index| stats[index] /= 1e9 unless index == ALLOCATIONS }
	end

	private def report(file, index, result, (process, slot, sequence))
		file.reported!
		result = result.merge("quarantined" => true) if @flakes.quarantined?(file, index, result)
		@outcome.record(result)
		@flakes.add(file, index, result) if result["passed_on_retry"] && !@warm_loaders
		@reporter.result(file.display_path, file.tests[index], result)
		# Its last final result, after any retries.
		@reporter.finished_file(file.display_path, file.variant) if file.reported == file.size
		@stopping = true if @fail_fast && failed?(result) && !result["quarantined"]

		@history&.add(file, index, result, process, slot, sequence)
	end

	private def load_failed(path, group, error)
		display_path = display_path(path)
		@partly_run[display_path] = true
		@outcome.load_failed
		@reporter.load_failed(display_path, error, @variants[group])
		@load_errors << [display_path, error]
		@stopping = true if @fail_fast
	end

	private def crashed(worker)
		@debug_queue.delete(worker)
		if @debugger.equal?(worker)
			system("stty", @terminal_settings, in: $stdin) if @terminal_settings
			take_terminal(worker)
		end

		# After Ctrl-C, a worker exiting is expected, and its test didn't finish.
		return abandon(worker) if @interrupted

		remove(worker)
		worker.channel.close
		@timeline&.exited(worker)
		output = Quickdraw::Capture.collect(worker.output_path) if worker.output_path

		crash = if (timeout = worker.timeout)
			timeout_error(*timeout)
		else
			{
				"name" => "Quickdraw::WorkerCrashed",
				"message" => "The worker process exited unexpectedly.",
				"backtrace" => [],
			}
		end

		@retries.release(worker)

		if (attempt = worker.retrying)
			report_retry(attempt, attempt.crashed(crash))
		elsif (path = worker.loading)
			# What it printed before crashing, which may say why.
			@reporter.printed(output) if output && @capture == :loading

			if (file = @files[[path, worker.group]])
				# It loaded elsewhere but crashed this worker, so don't let it take more.
				file.unstealable = true
			else
				load_failed(path, worker.group, crash)
			end
		elsif (batch = worker.batch)
			file, indices = batch

			if worker.started
				index, *rest = indices

				# A worker that times a test out sends the results it had waiting
				# first, so the test is the first without one.
				if rest.empty? || worker.timeout
					file.pending.unshift(*rest)
					file.crash_found(index)
					report(file, index, {
						"assertions" => 0, "failures" => [], "errors" => [crash], "duration" => nil, "output" => output
					}, placement(worker))
				else
					file.suspect(indices, output)
					file.pending.unshift(*indices)
				end
			else
				file.pending.unshift(*indices)
			end
		end

		replace(worker)
	end

	private def dispatch
		return if @idle.empty? && @free_slots.empty?

		release_slots unless @held_slots.empty? || @stopping

		# In the order they started, not the order they became idle.
		idle = @idle.empty? ? [] : @workers.each_value.select(&:idle)
		all_idle = idle.size == @workers.size

		# With --fail-fast, batches already running finish, but nothing new starts.
		idle = [] if @stopping

		# Slots freed by crashes, or by a group that failed to boot, go where the work is.
		until @stopping || @free_slots.empty? || !(loader = @scheduler.busiest_loader)
			start_worker(loader, @free_slots.shift)
		end

		idle.each do |worker|
			if (attempt = worker.queued_retries.shift)
				worker.retrying = attempt
				run_retry(worker)
			elsif worker.retrying
				run_retry(worker)
			elsif worker.fresh && (attempt = @retries.take(worker.group))
				worker.retrying = attempt
				load(worker, attempt.file.path)
			elsif spare_for?(worker.loader) && @retries.refresh(worker.group)
				# A fresh worker starts in its slot once this one exits.
				move(worker, worker.loader)
			elsif (file = slowest_waiting(worker))
				worker.loaded[file.path] ? run_batch(worker, file) : load(worker, file.path)
			elsif (file = own_file(worker))
				run_batch(worker, file)
			elsif (path = next_unloaded(worker.group))
				load(worker, path)
			elsif (file = file_to_steal(worker, all_idle))
				load(worker, file.path)
			elsif (loader = @scheduler.busiest_loader(except: worker.loader))
				move(worker, loader)
			end
		end

		return unless all_idle && @workers.each_value.all?(&:idle)

		# Not done until they exit, after sending their coverage.
		@timeline&.stopped
		@workers.each_value do |worker|
			worker.channel.write([:stop])
			@timeline&.stopping(worker)
			@leaving[worker.channel.reader] = [worker, nil]
		end

		@workers.clear
		@idle.clear
	end

	# Frees slots held at the start, a worker for each
	# WorkerTuner::MINIMUM_WORK_PER_WORKER of tests waiting in loaded files,
	# which workers that start now can take from those running them.
	private def release_slots
		waiting = @files.each_value.sum { |file| (file.unstealable || file.pending.empty?) ? 0.0 : file.estimated_pending_time || 0.0 }
		release((waiting / Quickdraw::WorkerTuner::MINIMUM_WORK_PER_WORKER).floor - @workers.size)
	end

	# Up to `count` of the slots held at the start, for dispatching to start workers in.
	private def release(count)
		released = @held_slots.shift([count, 0].max)
		@free_slots.concat(released)
		released.each { @released_at << now }
		released.size
	end

	private def idle(worker)
		worker.idle = true
		@idle[worker] = true
	end

	private def busy(worker)
		worker.idle = false
		@idle.delete(worker)
	end

	# No longer one of the run's workers.
	private def remove(worker)
		@workers.delete(worker.channel.reader)
		@idle.delete(worker)
	end

	# The slowest unloaded file in `group` (see #order_slowest_files_first).
	private def next_unloaded(group)
		index = @unloaded.index { |_path, _display_path, file_group| file_group == group } or return
		@unloaded.delete_at(index).first
	end

	# Stops the worker, and once it has exited (see #left), starts one in its
	# slot in `loader`. Not before, since its at_exit hooks may still be using
	# the slot's resources, such as a database.
	private def move(worker, loader)
		worker.channel.write([:stop])
		@timeline&.stopping(worker)
		remove(worker)
		@leaving[worker.channel.reader] = [worker, loader]
	end

	# `loader` is where the worker was moving to, or nil at the end of the run.
	private def left(reader)
		worker, loader = @leaving.delete(reader)
		worker.channel.close
		@timeline&.exited(worker)

		if loader && @scheduler.work_left?(loader.group)
			start_worker(loader, worker.slot)
		else
			@free_slots << worker.slot
		end
	end

	private def own_file(worker)
		worker.loaded.each_value.grep(TestFile).select { |file| file.pending.any? }.max_by { |file| file.pending.size }
	end

	# When every worker is idle, nothing else will pick up the work, so steal regardless of cost.
	private def file_to_steal(worker, all_idle)
		candidates = @files.each_value.reject do |file|
			file.unstealable || worker.loaded.key?(file.path) || file.pending.empty? || file.group != worker.group
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

	# The file whose next test is the slowest waiting in the worker's group (see
	# TestFile#slow?), counting the time to load it if the worker hasn't. Taken
	# before anything else, so slow tests start early and in parallel.
	private def slowest_waiting(worker)
		@slow_files.delete_if { |file, _| file.slow_pending == 0 }

		candidates = @slow_files.each_key.filter_map do |file|
			next if file.unstealable || file.group != worker.group
			next if worker.loaded[file.path] == false

			# Workers already loading it will take as many of its slow tests.
			next if !worker.loaded[file.path] && @workers.each_value.count { |other| other.loading == file.path && other.group == file.group } >= file.slow_pending

			worth = file.next_expected - (worker.loaded[file.path] ? 0 : file.load_duration)
			[file, worth] if worth >= BATCH_BUDGET
		end

		candidates.max_by { |_file, worth| worth }&.first
	end

	private def orphaned?(file)
		@workers.each_value.none? { |worker| worker.loaded[file.path].equal?(file) }
	end

	# Not after Ctrl-C, when workers are being stopped.
	private def give_terminal
		return if @interrupted

		worker = @debug_queue.shift or return
		# To restore if the worker dies while its debugger has the terminal raw.
		@terminal_settings = IO.popen(["stty", "-g"], in: $stdin, err: File::NULL, &:read).chomp if $stdin.tty?
		# Before this process ignores Ctrl-C, so workers ignore it too.
		File.write(Quickdraw::Debugger.flag_path, "")
		@debugger = worker
		@reporter.pause
		worker.channel.write([:debug])
	end

	private def take_terminal(worker)
		raise "Expected #{worker.pid} to have the terminal, but #{@debugger&.pid.inspect} has it." unless @debugger.equal?(worker)

		@debugger = nil
		File.delete(Quickdraw::Debugger.flag_path)
		@reporter.resume
		give_terminal
	end

	private def run_batch(worker, file)
		# A worker runs its whole batch, so with --fail-fast, one test at a time
		# stops promptly after a problem.
		indices = @fail_fast ? file.pending.shift(1) : file.next_batch
		worker.batch = [file, indices.dup]
		worker.started = false
		busy(worker)
		worker.fresh = false
		@timeline&.running(worker, file, indices)
		crashed(worker) unless worker.channel.write([:run, file.path, indices])
	end

	# The worker has loaded the file for its retry, and nothing else.
	private def run_retry(worker)
		attempt = worker.retrying
		worker.batch = [attempt.file, [attempt.index]]
		worker.started = false
		busy(worker)
		worker.fresh = false
		@timeline&.running(worker, attempt.file, [attempt.index])
		crashed(worker) unless worker.channel.write([:run, attempt.file.path, [attempt.index]])
	end

	private def load(worker, path)
		worker.loading = path
		busy(worker)
		# Loading a file runs its top-level code, which a retry shouldn't follow.
		worker.fresh = false unless worker.retrying
		@timeline&.loading(worker, display_path(path))
		crashed(worker) unless worker.channel.write([:load, path])
	end

	private def display_path(path)
		@display_paths.fetch(path)
	end
end
