# frozen_string_literal: true

# Tunes Ruby in each worker for the work history expects of it (see
# Coordinator#expected_work): the seconds it keeps a core busy running tests.
#
# YJIT: compiling costs a worker 25ms before it has run a test, and 150ms
# over a second of varied code, which only a hot loop repays sooner. So only
# workers with seconds of work get it. It's enabled in each worker (0.3ms)
# rather than the loader, which runs no tests, so has nothing compiled to
# share, and in watch mode outlives the run.
#
# Deferred GC: a worker's first GC, however small, writes to the heap it
# shares with the loader, which copies it: 3ms with 160,000 objects, and 13ms
# with 2,000,000. A worker with little work can finish without one.
module Quickdraw::Runtime
	extend self

	TUNINGS = ["yjit", "defer_gc"].freeze

	# Seconds of work per worker from which YJIT is enabled.
	YJIT_FROM = 2.0

	# Seconds of work per worker under which GC is deferred.
	DEFER_GC_UNDER = 0.5

	# A worker's GC is deferred until its heap and what it has allocated
	# outside it have grown by this much, or for this long, so one that does
	# more than history expected uses little more memory than it would have.
	DEFERRED_BYTES = 64 * 1024 * 1024
	DEFERRED_SECONDS = 5

	# How often a worker checks how much it has grown, in seconds.
	CHECK_INTERVAL = 0.02

	# The tunings for a run. `work` is nil when history can't say, which
	# chooses none. `yjit` and `defer_gc` are true or false to override it.
	def choose(work, yjit: nil, defer_gc: nil)
		yjit = !work.nil? && work >= YJIT_FROM if yjit.nil?
		defer_gc = !work.nil? && work < DEFER_GC_UNDER if defer_gc.nil?

		[("yjit" if yjit && yjit_available?), ("defer_gc" if defer_gc)].compact
	end

	# In a worker, before it loads tests.
	def apply(tunings)
		tunings.each do |tuning|
			case tuning
			in "yjit" then RubyVM::YJIT.enable
			in "defer_gc" then defer_gc
			end
		end
	end

	# Ends a deferral, if there is one.
	def resume_gc
		GC.enable if @deferring
		@deferring = false
	end

	# So a process a test forks, which the thread below isn't in, collects as usual.
	module Fork
		def _fork = super.tap { |pid| Quickdraw::Runtime.resume_gc if pid == 0 }
	end

	# Ruby runs one JIT at a time.
	private def yjit_available?
		Quickdraw::Platform.yjit_supported? && !(defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?)
	end

	private def defer_gc
		# Config turned it off already, so it's config's to turn on.
		return if GC.disable

		@deferring = true
		Process.singleton_class.prepend(Fork)
		limit = grown + DEFERRED_BYTES
		deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DEFERRED_SECONDS
		# Rather than sleep, which a test can stub.
		timer = Thread::Queue.new

		thread = Thread.new do
			timer.pop(timeout: CHECK_INTERVAL) until grown >= limit || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
			resume_gc
		end

		thread.name = "quickdraw-gc"
	end

	# The heap's size and what's been allocated outside it since the last GC, in bytes.
	private def grown
		(GC.stat(:heap_allocated_pages) * GC::INTERNAL_CONSTANTS[:HEAP_PAGE_SIZE]) + GC.stat(:malloc_increase_bytes)
	end
end
