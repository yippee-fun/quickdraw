# frozen_string_literal: true

# Runs in a forked process alongside user code, so it must only use core Ruby.
#
# Everything sent to the coordinator is converted to plain strings, numbers,
# arrays and hashes, since user objects may not survive Marshal.
class Quickdraw::Worker
	ANONYMOUS_MODULE = /#<Module:0x\h+>::/
	# Keys in a result with no output or leaks (see Recorder#to_h).
	PLAIN_RESULT_SIZE = 8

	# How often to check that a fork running mutation tests is still alive.
	FORK_CHECK_INTERVAL = 0.1

	# How long past its tests' timeouts to wait for a baseline fork before killing it.
	BASELINE_GRACE = 5

	class Recorder
		PHASE_INDICES = Quickdraw::PHASES.each_with_index.to_h.freeze
		CPU = Quickdraw::STATS.index("cpu")
		GC_TIME = Quickdraw::STATS.index("gc")
		ALLOCATIONS = Quickdraw::STATS.index("allocations")

		# Not every Ruby implementation has these. Without a CPU clock, CPU time
		# equals wall time and nothing is reported as waiting.
		CPU_CLOCK = Process.const_defined?(:CLOCK_PROCESS_CPUTIME_ID) ? Process::CLOCK_PROCESS_CPUTIME_ID : Process::CLOCK_MONOTONIC
		GC_KEYS = GC.stat.keys.freeze

		def initialize
			@assertions = 0
			@failures = []
			@errors = []
			@stats = Array.new(Quickdraw::STATS.size, 0)
			@duration = nil
			@skipped = nil
			@profile = nil
			@counts = nil
			@output = nil
			@leaks = nil
		end

		# Records the wall time of a phase of the test. Only the wall clock is read,
		# since it's ~30ns against ~200ns for the CPU clock. A phase that runs more
		# than once (e.g. a retrying around hook) accumulates.
		def measure(phase)
			index = PHASE_INDICES.fetch(phase)
			started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
			yield
		ensure
			@stats[index] += Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - started_at
		end

		# Records the whole test's duration, CPU time, GC time and allocations.
		# CPU time includes that of processes the test started and waited for (and
		# theirs), since a test waiting on a busy process isn't idle.
		def measure_test
			wall = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
			cpu = Process.clock_gettime(CPU_CLOCK, :nanosecond)
			children = children_cpu
			gc = gc_milliseconds
			allocations = allocated_objects
			Quickdraw::Counters.start

			yield
		ensure
			@counts = Quickdraw::Counters.take
			@duration = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - wall
			@stats[CPU] = Process.clock_gettime(CPU_CLOCK, :nanosecond) - cpu + (children_cpu - children)
			@stats[GC_TIME] = (gc_milliseconds - gc) * 1_000_000
			@stats[ALLOCATIONS] = allocated_objects - allocations
		end

		def success!(_description)
			@assertions += 1
		end

		def failure!(failure)
			return @late.call(failure) if @late

			@assertions += 1
			@failures << failure
		end

		def error!(error)
			@errors << error
		end

		def skip!(reason)
			@skipped = { "pending" => false, "reason" => reason && Quickdraw.utf8(Quickdraw.plain_string(reason)) }
		end

		def pending!
			@skipped = { "pending" => true, "reason" => nil }
		end

		# From Sampler#record, with --profile.
		attr_writer :profile

		# What the test printed, only kept if it failed or errored.
		attr_writer :output

		# From Leaks#check, as warnings.
		attr_accessor :leaks

		def problem? = @failures.any? || @errors.any?

		# Once its result is sent: a failure a thread the test started makes
		# after that goes to the block, rather than being lost.
		def close(&late)
			@late = late
		end

		# Output and leaks only when there are some, since each key sent costs
		# about 250ns.
		def to_h
			result = {
				"assertions" => @assertions,
				"failures" => @failures,
				"errors" => @errors,
				"skipped" => @skipped,
				"stats" => @stats,
				"duration" => @duration,
				"profile" => @profile,
				"counts" => @counts,
			}

			result["output"] = @output if @output
			result["leaks"] = @leaks if @leaks
			result
		end

		# In nanoseconds, of child processes that have been waited for.
		private def children_cpu
			times = Process.times
			((times.cutime + times.cstime) * 1_000_000_000).round
		end

		private def gc_milliseconds
			GC_KEYS.include?(:time) ? GC.stat(:time) : 0
		end

		private def allocated_objects
			GC_KEYS.include?(:total_allocated_objects) ? GC.stat(:total_allocated_objects) : 0
		end
	end

	# `timeouts` is false where the worker shares a process with the coordinator,
	# since timing out exits the worker's process. `profile` samples tests.
	# `capture` attributes what tests print to them (see Capture), and with
	# :loading also sends what loading a file prints, for the reporter to print
	# whole, rather than mixed into its lines. `leaks` is :warn or :fail
	# to check for state tests leave behind (see Leaks), or nil.
	def initialize(channel, test_files, seed, timeouts: true, profile: false, coverage: false, capture: false, leaks: nil)
		raise ArgumentError, "leaks must be :warn, :fail or nil, not #{leaks.inspect}" unless leaks in :warn | :fail | nil
		raise ArgumentError, "capture must be true, false or :loading, not #{capture.inspect}" unless capture in true | false | :loading

		@channel = channel
		@test_files = test_files
		@seed = seed
		@timeouts = timeouts
		@profile = profile
		@coverage = coverage
		@capture_output = capture
		@leak_mode = leaks
		@coverage_totals = {}
		@files = {}
		@file_seeds = {}
		@class_names = {}
		# Failures threads made after the tests that started them finished, as
		# leaks, for the test running when they're found.
		@late = Thread::Queue.new
	end

	def call
		@sampler = Quickdraw::Sampler.new if @profile

		if @timeouts
			@watchdog = Quickdraw::Watchdog.new do |seconds, threads|
				@channel.write([:timeout, seconds, threads])
			end
		end

		if @capture_output
			begin
				@capture = Quickdraw::Capture.new
				# So the coordinator can show what a test printed if it kills the worker.
				@channel.write([:capturing, @capture.path])
			rescue SystemCallError => error
				warn "Quickdraw couldn’t create a file to capture what tests print in (#{error.message}), so it’s shown as it’s printed."
			end
		end

		# After the watchdog and sampler start, so their threads aren't leaks.
		@leaks = Quickdraw::Leaks.new(Dir.pwd) if @leak_mode
		@terminal_turn = Thread::Queue.new([true])
		Quickdraw::Debugger.install(self)

		@channel.write([:ready, Process.pid])

		while (message = read_command)
			case message
			in [:load, path]
				@capture.start if @capture && @capture_output == :loading
				loaded = load(path)

				if @capture && @capture_output == :loading
					@capture.stop
					printed = @capture.take(whole: true)
					@channel.write([:printed, printed]) if printed
				end

				@leaks&.reset
				Quickdraw::Debugger.hook_debug_gem
				covered(path) if @coverage
				@channel.write(loaded)
			in [:run, path, indices]
				@channel.write([:started])
				tests = @files.fetch(path)
				@capture&.start

				indices.each do |index|
					seed(path, index)
					@channel.write([:result, index, self.class.compact(run(tests[index]))])
				end

				@capture&.stop
				covered(path) if @coverage
				@channel.write([:ready, Process.pid])
			in [:baseline, path, subjects]
				@channel.write([:baseline, path, *baseline(path, subjects)])
			in [:mutant, mutant, tests, seconds, matrix]
				outcome, row = matrix ? mutate_every_test(mutant, tests, seconds) : [mutate(mutant, tests, seconds), nil]
				@channel.write([:mutant, mutant.id, outcome, row])
			in [:fuzz, path, index, settings]
				Quickdraw::Fuzz::Session.new(@channel, @files.fetch(path).fetch(index), test_seed: test_seed(path, index), **settings).call
			in [:stop]
				# The coordinator stops listening, so it can no longer give out the terminal.
				Quickdraw::Debugger.uninstall
				@channel.write([:coverage, Quickdraw::CoverageCollector.merge(@coverage_totals, Quickdraw::CoverageCollector.take)]) if @coverage
				break
			end
		end
	rescue Quickdraw::Interrupted
		nil
	ensure
		@capture&.close
	end

	# Takes what loading or running the file's tests covered, for the map of
	# which source files each test file runs (see History#record_coverage_map).
	# Taking it per batch rather than per test, since with branches and methods
	# it takes about 9ms for 100,000 lines of code.
	private def covered(path)
		files = Quickdraw::CoverageCollector.take
		Quickdraw::CoverageCollector.merge(@coverage_totals, files)
		@channel.write([:covered, path, Quickdraw::CoverageCollector.run(files)])
	end

	private def load(path)
		started_at = now
		scope = Module.new

		# Loading can hang too (a file that connects to something at load time,
		# say), so it has the same timeout as a test.
		tests = Quickdraw.collect_tests(path, @test_files) do
			if @watchdog
				@watchdog.watch(Quickdraw::Config.timeout) { Kernel.load(path, scope) }
			else
				Kernel.load(path, scope)
			end
		end

		# The file's top-level methods are defined on its scope, so test classes
		# defined in the file include it to call them. Classes reopened from
		# elsewhere don't, or the helpers would leak to other files' tests.
		scope.constants.each do |name|
			test_class = scope.const_get(name)
			test_class.include(scope) if Class === test_class && test_class < Quickdraw::BasicTest
		end

		@files[path] = tests
		@file_seeds[path] = Quickdraw.stable_hash("#{@seed}:#{path.delete_prefix("#{Dir.pwd}/")}")

		[:loaded, path, tests.map { |test| describe(test) }, now - started_at]
	rescue Quickdraw::Interrupted
		raise
	rescue Exception => error
		[:load_failed, path, Quickdraw.serialize_error(error)]
	end

	# A passing test's result as just its numbers, which is several times quicker
	# to send and to read. See .result.
	def self.compact(result)
		plain = result.size == PLAIN_RESULT_SIZE && result["failures"].empty? && result["errors"].empty? && !result["skipped"] && !result["profile"]
		plain ? [result["duration"], result["stats"], result["assertions"], result["counts"]] : result
	end

	# A result as Recorder#to_h made it, from what .compact sent.
	def self.result(sent)
		case sent
		in Hash then sent
		in [duration, stats, assertions, counts]
			{ "assertions" => assertions, "failures" => [], "errors" => [], "skipped" => nil, "stats" => stats, "duration" => duration, "profile" => nil, "counts" => counts }
		end
	end

	private def describe(definition)
		if definition.timeout && !@timeouts && !@warned_about_timeouts
			warn "Test timeouts need fork, which this platform doesn’t support, so they aren’t enforced."
			@warned_about_timeouts = true
		end

		{
			"description" => definition.description&.then { |it| without_anonymous_modules(Quickdraw.utf8(Quickdraw.plain_string(it))) },
			"line" => definition.line,
			# Once per named class, since test files load in an anonymous module, so
			# each name has one to remove. Not while it's anonymous: it can be named later.
			"class_name" => (@class_names[definition.test_class] ||= definition.test_class.name&.then { |it| without_anonymous_modules(Quickdraw.utf8(it)) }),
			# So the coordinator can kill a worker whose watchdog can't run.
			"timeout" => (definition.timeout || Quickdraw::Config.timeout if @timeouts),
			**(definition.mutation ? {} : { "mutation" => false }),
		}
	end

	private def without_anonymous_modules(name)
		name.include?("#<Module:") ? name.gsub(ANONYMOUS_MODULE, "") : name
	end

	private def run(definition)
		recorder = Recorder.new

		recorder.measure_test do
			next recorder.pending! unless definition.block

			test = definition.test_class.new(description: definition.description, block: definition.block, runner: recorder)
			seconds = definition.timeout || Quickdraw::Config.timeout

			if @watchdog
				overran = @watchdog.watch(seconds) { run_test(test, recorder) }

				if overran
					recorder.error!({
						"name" => "Quickdraw::Timeout",
						"message" => "The test took longer than its #{seconds}s timeout.",
						"backtrace" => [],
					})
				end
			else
				run_test(test, recorder)
			end
		rescue Quickdraw::Interrupted
			raise
		rescue Exception => error
			recorder.error!(Quickdraw.serialize_error(error))
		end

		# Taken from every test, so the next one starts empty.
		output = if @capture
			@capture.take
		else
			flush_output
			nil
		end

		if @leaks
			leaks = [*@leaks.check, *late_failures]

			if leaks.any?
				if @leak_mode == :fail
					recorder.error!({ "name" => "Quickdraw::Leak", "message" => leaks.map { |leak| leak["message"] }.join("\n"), "backtrace" => [] })
				else
					recorder.leaks = leaks
				end
			end
		end

		recorder.output = output if output && recorder.problem?
		result = recorder.to_h

		# A thread the test left running may fail an assertion yet, which is a leak.
		if @leaks
			name = "#{Quickdraw::Filter.name_of(describe(definition))} (line #{definition.line})"
			recorder.close { |failure| @late << { "kind" => "late failure", "message" => Quickdraw.utf8("After #{name} finished, a thread it started failed an assertion at #{failure['path'].delete_prefix("#{Dir.pwd}/")}:#{failure['line']}: #{failure['message']}") } }
		end

		result
	end

	private def late_failures
		Array.new(@late.size) { @late.pop }
	end

	# Runs the file's tests unmutated, tracing what they run of `subjects` (see
	# Mutation::Tracer), in a fork so that what they leave behind, such as
	# memoized values, can't reach mutants. Returns the ids of the subjects
	# traced and each test's result with its "lines", or nil if the fork died
	# or took longer than all its tests' timeouts, which a test holding the GVL
	# keeps the fork's watchdog from noticing.
	private def baseline(path, subjects)
		timeouts = @files.fetch(path).map { |test| test.timeout || Quickdraw::Config.timeout }
		seconds = (timeouts.sum + BASELINE_GRACE unless timeouts.include?(nil))

		outcome = in_fork(seconds) do
			# Its thread didn't survive the fork.
			@watchdog &&= Quickdraw::Watchdog.new { nil }
			tracer = Quickdraw::Mutation::Tracer.new
			traced = tracer.trace(subjects)

			results = @files.fetch(path).each_with_index.map do |test, index|
				seed(path, index)
				run(test).merge("lines" => tracer.take)
			end

			[traced, results]
		end

		outcome unless outcome == :timeout
	end

	# Runs `tests`, as [path, index], against `mutant` in a fork until one fails.
	# Returns the outcome: ["killed", [path, index]] with the test that failed,
	# ["survived"], ["timeout"] after `seconds`, ["crashed"], or ["unapplied", why].
	private def mutate(mutant, tests, seconds)
		outcome = in_fork(seconds) do
			# Its thread didn't survive the fork. This process times the fork out instead.
			@watchdog = nil
			run_mutant(mutant, tests)
		end

		case outcome
		in nil then ["crashed"]
		in :timeout then ["timeout"]
		else outcome
		end
	end

	# For --matrix: runs every one of `tests` against `mutant` in a fork, rather
	# than stopping at the first to fail, and returns the outcome #mutate would,
	# with a row of which tests killed it: { "killed" => [[path, index]], "ran"
	# => count, "complete" => whether every test ran }. Each test's outcome
	# comes as it's known, so a later test that crashes or hangs the fork
	# leaves the row incomplete, not lost, and a kill before it still counts.
	private def mutate_every_test(mutant, tests, seconds)
		Quickdraw::Property.directory = File::NULL
		reader, writer = IO.pipe
		deadline = seconds && (now + seconds)

		pid = Process.fork do
			reader.close
			@watchdog = nil

			begin
				mutant.apply
			rescue Quickdraw::Interrupted
				raise
			rescue Exception => error
				writer.write(Quickdraw::Channel.encode([:unapplied, Quickdraw.plain_string("#{error.class}: #{error.message}")]))
				next
			end

			tests.each do |path, index|
				seed(path, index)
				result = run(@files.fetch(path).fetch(index))
				writer.write(Quickdraw::Channel.encode([:test, path, index, result["failures"].any? || result["errors"].any?]))
			end

			writer.write(Quickdraw::Channel.encode([:done]))
		ensure
			exit!(0)
		end

		writer.close
		killed = []
		ran = 0
		ending = nil

		until ending
			# Watches the fork as well as the pipe, which a process a test started can hold open.
			unless reader.wait_readable(deadline ? (deadline - now).clamp(0, FORK_CHECK_INTERVAL) : FORK_CHECK_INTERVAL)
				ending = :timeout if deadline && now >= deadline
				next unless !ending && pid && exited?(pid)

				pid = nil
				# What it wrote before exiting is still to be read.
				ending = :crashed unless reader.wait_readable(0)
				next
			end

			case read_message(reader)
			in [:test, path, index, failed]
				ran += 1
				killed << [path, index] if failed
			in [:unapplied, reason] then return [["unapplied", reason], nil]
			in [:done] then ending = :done
			in nil then ending = :crashed
			end
		end

		outcome = if killed.any? then ["killed", killed.first]
		elsif ending == :done then ["survived"]
		elsif ending == :timeout then ["timeout"]
		else ["crashed"]
		end

		[outcome, { "killed" => killed, "ran" => ran, "complete" => ending == :done }]
	ensure
		reader&.close
		writer&.close
		stop_fork(pid) if pid
	end

	# A length-prefixed message from a fork, or nil at the end of the pipe.
	private def read_message(reader)
		header = reader.read(4)
		data = reader.read(header.unpack1("N")) if header&.bytesize == 4
		Marshal.load(data) if data
	end

	private def stop_fork(pid)
		Process.kill(:KILL, pid)
	rescue Errno::ESRCH
		nil
	ensure
		begin
			Process.wait(pid)
		rescue Errno::ECHILD
			# Already reaped, as for exited?.
			nil
		end
	end

	# Returns what the block returns in a fork of this worker, so what it changes
	# dies with the fork. Nil if the fork exits first, or :timeout once it's
	# taken `seconds`, which kills it.
	private def in_fork(seconds)
		# So a property's failing case is neither replayed in the fork nor saved
		# from it, where it would change other mutants' runs.
		Quickdraw::Property.directory = File::NULL
		reader, writer = IO.pipe
		deadline = seconds && (now + seconds)

		pid = Process.fork do
			reader.close
			data = Marshal.dump(yield)
			writer.write([data.bytesize].pack("N"), data)
		ensure
			# Without at_exit hooks, which are the worker's to run.
			exit!(0)
		end

		writer.close

		# Watches the fork as well as the pipe, which a process a test started
		# can hold open after the fork has gone.
		until reader.wait_readable(deadline ? (deadline - now).clamp(0, FORK_CHECK_INTERVAL) : FORK_CHECK_INTERVAL)
			return :timeout if deadline && now >= deadline
			next unless exited?(pid)

			pid = nil
			return unless reader.wait_readable(0)

			break
		end

		# Length-prefixed rather than read to the end, for the same reason.
		header = reader.read(4)
		data = reader.read(header.unpack1("N")) if header&.bytesize == 4
		Marshal.load(data) if data
	ensure
		reader&.close
		writer&.close

		if pid
			begin
				Process.kill(:KILL, pid)
			rescue Errno::ESRCH
				nil
			end

			begin
				Process.wait(pid)
			rescue Errno::ECHILD
				# Already reaped, as for exited?.
				nil
			end
		end
	end

	# Reaps the fork if it has exited. Config that ignores SIGCHLD, or reaps in
	# a handler, can have reaped it already.
	private def exited?(pid)
		!!Process.wait2(pid, Process::WNOHANG)
	rescue Errno::ECHILD
		true
	end

	private def run_mutant(mutant, tests)
		begin
			mutant.apply
		rescue Quickdraw::Interrupted
			raise
		rescue Exception => error
			return ["unapplied", Quickdraw.plain_string("#{error.class}: #{error.message}")]
		end

		tests.each do |path, index|
			seed(path, index)
			result = run(@files.fetch(path).fetch(index))
			return ["killed", [path, index]] if result["failures"].any? || result["errors"].any?
		end

		["survived"]
	end

	# Seeded by test rather than by process, so `rand` in a test gives the same
	# values for a given run seed whichever worker runs it, and when a mutant
	# runs it. In 32 bits, which Ruby seeds about 3x as fast.
	private def seed(path, index)
		Kernel.srand(test_seed(path, index))
	end

	private def test_seed(path, index)
		(@file_seeds.fetch(path) + index) & 0xFFFF_FFFF
	end

	private def run_test(test, recorder)
		if @sampler
			_, recorder.profile = @sampler.record { test.run }
		else
			test.run
		end
	end

	# Runs a debugger that returns when it's done (see Debugger) with the
	# terminal, once the coordinator gives it, and the test's output and
	# timeout paused.
	def holding_terminal
		# Already this thread's, or the debug gem's, which stops other threads
		# while it has the terminal, so this was run from its prompt.
		return yield if @terminal_holder.equal?(Thread.current) || @terminal_holder == :debug_gem

		# Interrupts, such as a Timeout around the debugger, wait until the
		# coordinator has the terminal back.
		Thread.handle_interrupt(Object => :never) do
			take_terminal(Thread.current)
			Thread.handle_interrupt(Object => :immediate) { yield }
		ensure
			give_back_terminal if @terminal_holder.equal?(Thread.current)
		end
	end

	# The test's timeout is paused while it waits for the terminal, too.
	# Another thread's debugger waits its turn. Not a Mutex, as the debug gem
	# gives the terminal back from another thread.
	def take_terminal(holder)
		@terminal_turn.pop
		@watchdog&.pause
		@channel.write([:debugging])
		message = @channel.read
		raise "Expected the coordinator to give this worker the terminal, but got #{message.inspect}." unless message == [:debug]

		# Capture is off while a file loads, and stays off.
		@capture_after_debugger = @capture&.capturing?
		@capture&.stop
		@terminal_holder = holder
	end

	def give_back_terminal
		@terminal_holder = nil
		@capture.start if @capture_after_debugger
		@channel.write([:debugged])
		@watchdog&.resume
		@terminal_turn << true
	end

	def has_terminal? = !@terminal_holder.nil?

	# A debugger in another thread reads the coordinator's answer from the same
	# channel, so they take turns.
	private def read_command
		@terminal_turn.pop

		begin
			@channel.read
		ensure
			@terminal_turn << true
		end
	end

	# Without capture. Workers start unbuffered, but a test or config can replace
	# $stdout. Without this, a later test that crashes the worker would lose what
	# earlier tests printed. Free when nothing was printed.
	private def flush_output
		$stdout.flush
		$stderr.flush
	rescue IOError
		nil
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
