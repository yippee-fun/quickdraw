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

		def to_h
			{ "assertions" => @assertions, "failures" => @failures, "errors" => @errors, "stats" => @stats, "duration" => @duration }
		end

		private def gc_milliseconds
			GC_KEYS.include?(:time) ? GC.stat(:time) : 0
		end

		private def allocated_objects
			GC_KEYS.include?(:total_allocated_objects) ? GC.stat(:total_allocated_objects) : 0
		end
	end

	def initialize(channel, test_files, seed)
		@channel = channel
		@test_files = test_files
		@seed = seed
		@files = {}
		@file_seeds = {}
	end

	def call
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
					@channel.write([:result, index, run(*tests[index])])
				end

				@channel.write([:ready, Process.pid])
			in [:stop]
				break
			end
		end
	end

	private def load(path)
		started_at = now
		tests = Quickdraw.collect_tests(path, @test_files) { Kernel.load(path, Module.new) }
		@files[path] = tests
		@file_seeds[path] = Quickdraw.stable_hash("#{@seed}:#{path.delete_prefix("#{Dir.pwd}/")}")

		[:loaded, path, tests.map { |test| describe(test) }, now - started_at]
	rescue Exception => error
		[:load_failed, path, Quickdraw.serialize_error(error)]
	end

	private def describe((test_class, description, block))
		{
			"description" => description&.then { |it| Quickdraw.plain_string(it).gsub(ANONYMOUS_MODULE, "") },
			"line" => block.source_location[1],
			"class_name" => test_class.name&.gsub(ANONYMOUS_MODULE, ""),
		}
	end

	private def run(test_class, description, block)
		recorder = Recorder.new
		recorder.measure_test { test_class.new(description:, block:, runner: recorder).run }
		recorder.to_h
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
