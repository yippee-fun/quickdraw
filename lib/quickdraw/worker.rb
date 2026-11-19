# frozen_string_literal: true

# Runs in a forked process alongside user code, so it must only use core Ruby.
#
# Everything sent to the coordinator is converted to plain strings, numbers,
# arrays and hashes, since user objects may not survive Marshal.
class Quickdraw::Worker
	ANONYMOUS_MODULE = /#<Module:0x\h+>::/

	class Recorder
		PHASE_INDICES = Quickdraw::PHASES.each_with_index.to_h.freeze
		CPU = Quickdraw::STATS.index("cpu")
		GC_TIME = Quickdraw::STATS.index("gc")
		ALLOCATIONS = Quickdraw::STATS.index("allocations")

		# Not every Ruby implementation has these. Without a CPU clock, CPU time
		# equals wall time and nothing is reported as waiting.
		CPU_CLOCK = Process.const_defined?(:CLOCK_PROCESS_CPUTIME_ID) ? Process::CLOCK_PROCESS_CPUTIME_ID : Process::CLOCK_MONOTONIC
		GC_KEYS = GC.stat.keys

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
			Quickdraw::Counters.take

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
		attr_writer :leaks

		def problem? = @failures.any? || @errors.any?

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
	# `capture` attributes what tests print to them (see Capture). `leaks` is
	# :warn or :fail to check for state tests leave behind (see Leaks), or nil.
	def initialize(channel, test_files, seed, timeouts: true, profile: false, coverage: false, capture: false, leaks: nil)
		raise ArgumentError, "leaks must be :warn, :fail or nil, not #{leaks.inspect}" unless leaks in :warn | :fail | nil

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

		@channel.write([:ready, Process.pid])

		while (message = @channel.read)
			case message
			in [:load, path]
				loaded = load(path)
				@leaks&.reset
				covered(path) if @coverage
				@channel.write(loaded)
			in [:run, path, indices]
				@channel.write([:started])
				tests = @files.fetch(path)
				file_seed = @file_seeds.fetch(path)
				@capture&.start

				indices.each do |index|
					# Seeded by test rather than by process, so `rand` in a test gives the
					# same values for a given run seed whichever worker runs it.
					Kernel.srand(file_seed + index)
					@channel.write([:result, index, run(tests[index])])
				end

				@capture&.stop
				covered(path) if @coverage
				@channel.write([:ready, Process.pid])
			in [:stop]
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

	private def describe(definition)
		{
			"description" => definition.description&.then { |it| Quickdraw.utf8(Quickdraw.plain_string(it)).gsub(ANONYMOUS_MODULE, "") },
			"line" => definition.line,
			"class_name" => definition.test_class.name&.then { |it| Quickdraw.utf8(it).gsub(ANONYMOUS_MODULE, "") },
			# So the coordinator can kill a worker whose watchdog can't run.
			"timeout" => (definition.timeout || Quickdraw::Config.timeout if @timeouts),
		}
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

		if @leaks && (leaks = @leaks.check)
			if @leak_mode == :fail
				recorder.error!({ "name" => "Quickdraw::Leak", "message" => leaks.map { |leak| leak["message"] }.join("\n"), "backtrace" => [] })
			else
				recorder.leaks = leaks
			end
		end

		if @capture
			# Taken from every test, so the next one starts empty.
			output = @capture.take
			recorder.output = output if recorder.problem?
		else
			flush_output
		end

		recorder.to_h
	end

	private def run_test(test, recorder)
		if @sampler
			_, recorder.profile = @sampler.record { test.run }
		else
			test.run
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
