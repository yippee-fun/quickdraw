# frozen_string_literal: true

# Samples a worker's main thread while a test runs, for --profile. Each sample
# counts every method on the stack once (inclusive) and the innermost one
# (self), weighted by the time since the previous sample. Quickdraw's own
# frames are left out, since they're in every sample.
#
# A thread waiting for the GVL gets it only every timeslice, 100ms by default,
# so --profile runs Ruby with RUBY_THREAD_TIMESLICE=1 where supported. Even so,
# samples come far more often while a test waits than while it computes, which
# is why they're weighted by time. Core Ruby only, since it runs in workers.
class Quickdraw::Sampler
	INTERVAL = 0.001
	QUICKDRAW = ["#{Quickdraw::LIB}/", "#{File.expand_path('../exe', Quickdraw::LIB)}/"].freeze
	WORKER = File.join(Quickdraw::LIB, "quickdraw/worker.rb")
	# With modifiers such as `private` before it.
	DEFINITION = /^\s*(?:[a-z_]+\s+)*def\s+(?:self\.)?([^\s(=;]+=?)/

	def initialize(thread = Thread.current)
		@thread = thread
		@lock = Thread::Mutex.new
		@samples = nil
		@definitions = {}
		Thread.new { loop { sleep INTERVAL; sample } }
	end

	# Returns the block's value and the samples taken while it ran: [count,
	# seconds sampled, { "label\0path\0line" => [inclusive seconds, self seconds] }].
	def record
		@lock.synchronize do
			@samples = {}
			@count = 0
			@sampled = 0.0
			@sampled_at = now
		end

		value = yield
		[value, finish]
	rescue Exception
		finish
		raise
	end

	private def finish
		@lock.synchronize do
			samples = [@count, @sampled, @samples]
			@samples = nil
			samples
		end
	end

	private def sample
		sampled_at = now
		locations = @thread.backtrace_locations or return

		@lock.synchronize do
			return unless @samples

			weight = sampled_at - @sampled_at
			@sampled_at = sampled_at
			@count += 1
			@sampled += weight
			innermost = true
			seen = {}

			locations.each do |location|
				path = location.absolute_path || location.path
				# The worker running the test, and everything that started it.
				break if path == WORKER
				next if path.nil? || path.start_with?(*QUICKDRAW)

				label = location.label
				key = "#{label}\0#{path}\0#{definition_line(path, label, location.lineno)}"
				seconds = (@samples[key] ||= [0.0, 0.0])
				seconds[0] += weight unless seen.key?(key)
				seconds[1] += weight if innermost
				seen[key] = true
				innermost = false
			end
		end
	end

	# Where the method running at `line` is defined: the nearest `def` of its
	# name at or above the line. Labels don't say which class a method is in
	# when the class is in a test file's anonymous scope, so this tells apart
	# methods with the same name. Nil for methods defined elsewhere, such as in C.
	private def definition_line(path, label, line)
		name = label.sub(/\Ablock (?:\(\d+ levels\) )?in /, "")[/[^#.]+\z/]
		return if name.nil? || name.start_with?("<")

		definitions = @definitions.fetch(path) do
			@definitions[path] = begin
				File.foreach(path).with_index(1).each_with_object({}) do |(source, number), lines|
					(lines[$1] ||= []) << number if DEFINITION =~ source.scrub
				end
			rescue SystemCallError
				{}
			end
		end

		definitions[name]&.select { |number| number <= line }&.max
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
