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
		def measure_test
			wall = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
			cpu = Process.clock_gettime(CPU_CLOCK, :nanosecond)
			gc = gc_milliseconds
			allocations = allocated_objects

			yield
		ensure
			@duration = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - wall
			@stats[CPU] = Process.clock_gettime(CPU_CLOCK, :nanosecond) - cpu
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

		def to_h
			{
				"assertions" => @assertions,
				"failures" => @failures,
				"errors" => @errors,
				"skipped" => @skipped,
				"stats" => @stats,
				"duration" => @duration,
				"profile" => @profile,
			}
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
	def initialize(channel, test_files, seed, timeouts: true, profile: false)
		@channel = channel
		@test_files = test_files
		@seed = seed
		@timeouts = timeouts
		@profile = profile
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

		@channel.write([:ready, Process.pid])

		while (message = @channel.read)
			case message
			in [:load, path]
				@channel.write(load(path))
			in [:run, path, indices]
				@channel.write([:started])
				tests = @files.fetch(path)
				file_seed = @file_seeds.fetch(path)

				indices.each do |index|
					# Seeded by test rather than by process, so `rand` in a test gives the
					# same values for a given run seed whichever worker runs it.
					Kernel.srand(file_seed + index)
					@channel.write([:result, index, run(tests[index])])
				end

				@channel.write([:ready, Process.pid])
			in [:stop]
				break
			end
		end
	rescue Quickdraw::Interrupted
		nil
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

		flush_output
		recorder.to_h
	end

	private def run_test(test, recorder)
		if @sampler
			_, recorder.profile = @sampler.record { test.run }
		else
			test.run
		end
	end

	# Workers start unbuffered, but a test or config can replace $stdout. Without
	# this, a later test that crashes the worker would lose what earlier tests
	# printed. Free when nothing was printed.
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
