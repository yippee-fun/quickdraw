# frozen_string_literal: true

# Finds state a test left behind, after every test: threads and Ractors it
# started that are still running, a fiber scheduler it set, child processes it
# didn't wait for, and changes to ENV. Unless a test started a thread or a
# process, or changed ENV, this only compares the scheduler and the thread and
# Ractor counts.
#
# Runs in the worker alongside user code, so it must only use core Ruby.
class Quickdraw::Leaks
	# Thread#inspect is "#<Thread:0x…@name path:line status>".
	THREAD_ADDRESS = /\A#<Thread:0x\h+/
	THREAD_LOCATION = /\A (?<path>.+):(?<line>\d+) \w+>\z/m

	# How long to wait for Process.detach's threads to reap children that have exited.
	DETACH_GRACE = 0.1

	# Comparing ENV takes several microseconds, so its writers set a flag.
	module ENVChanges
		singleton_class.attr_accessor :changed

		[:[]=, :store, :delete, :clear, :replace, :update, :merge!, :shift, :delete_if, :reject!, :select!, :filter!, :keep_if].each do |name|
			define_method(name) do |*arguments, &block|
				ENVChanges.changed = true
				super(*arguments, &block)
			end
		end
	end

	# Waiting for child processes takes a few microseconds, so the methods that
	# can leave one running set a flag. Not PTY.spawn, which is in a library.
	module ProcessStarts
		singleton_class.attr_accessor :started

		module Spawn
			def spawn(...)
				ProcessStarts.started = true
				super
			end
		end

		module PrivateSpawn
			private def spawn(...)
				ProcessStarts.started = true
				super
			end
		end

		# Called by every fork, including IO.popen("-").
		module Fork
			def _fork
				ProcessStarts.started = true
				super
			end
		end

		module Popen
			def popen(...)
				ProcessStarts.started = true
				super
			end
		end

		def self.watch
			Kernel.prepend(PrivateSpawn)
			Kernel.singleton_class.prepend(Spawn)
			Process.singleton_class.prepend(Spawn, Fork)
			IO.singleton_class.prepend(Popen)
		end

		def self.watching? = Process.singleton_class.include?(Fork)
	end

	# Threads started since the last check, so one that ended with an exception
	# nothing joined it to see can be reported, and whether each was joined.
	module ThreadStarts
		@threads = []
		# Those prune found had ended with an exception, so it doesn't check them again.
		@raised = []

		# Not in other Ractors, which can't reach this list, and whose threads
		# Thread.list doesn't have. Nor what a stub of Thread.new returns.
		def self.started(thread)
			@threads << thread if Thread === thread && (!defined?(Ractor) || Ractor.current.equal?(Ractor.main))
		end

		# Nil if there are none, as after nearly every test.
		def self.take
			return if @threads.empty? && @raised.empty?

			# Swapped first, so a thread started meanwhile isn't dropped.
			threads, @threads = @threads, []
			raised, @raised = @raised, []
			raised.concat(threads)
		end

		# Forgets threads that ended with nothing to report, so a property
		# whose cases each start one doesn't keep them all until its test ends.
		def self.prune
			return if @threads.empty?

			ended, @threads = @threads.partition { |thread| !thread.alive? }
			@raised.concat(ended.select { |thread| thread.status.nil? && !thread.quickdraw_joined? })
		end

		module Starting
			def new(...) = super.tap { |thread| ThreadStarts.started(thread) }
			def start(...) = super.tap { |thread| ThreadStarts.started(thread) }
			def fork(...) = super.tap { |thread| ThreadStarts.started(thread) }
		end

		module Joining
			# Only once it has ended, as a join with a timeout can return before.
			# In ensure, as rescuing and raising again here loses the exception.
			def join(...)
				super
			ensure
				@quickdraw_joined = true unless alive?
			end

			def value
				super
			ensure
				@quickdraw_joined = true unless alive?
			end

			def quickdraw_joined? = @quickdraw_joined
		end
	end

	# Threads are only reported if they started in `root`, outside vendor/, so
	# the threads libraries start for themselves (Timeout's, connection pool
	# reapers) aren't blamed on the first test to use them.
	def initialize(root)
		@root = "#{root}/"
		@vendor = "#{root}/vendor/"
		@library = "#{Quickdraw::LIB}/"
		ENV.singleton_class.prepend(ENVChanges)
		Thread.singleton_class.prepend(ThreadStarts::Starting)
		Thread.prepend(ThreadStarts::Joining)
		raise "ProcessStarts.watch must be called before after_forking callbacks." unless ProcessStarts.watching?
		# Not by waiting, which would reap a process config started and will wait for.
		@children = ProcessStarts.started ? :unknown : :none
		ProcessStarts.started = false
		reset
	end

	# What's there now is the starting point, e.g. after loading a file.
	def reset
		ThreadStarts.take
		@threads = Thread.list
		@scheduler = Fiber.scheduler
		@ractors = ractor_count
		@env = ENV.to_h
		ENVChanges.changed = false
		# A test file can start processes as it loads, which aren't its tests' leaks.
		@children = :unknown if ProcessStarts.started && @children == :none
		ProcessStarts.started = false
	end

	# Leaks since the last check or reset, as [{ "kind" =>, "message" => }], or nil.
	def check
		leaks = nil
		started = ThreadStarts.take

		threads = Thread.list

		# Comparing the lists takes as long as listing, so they're only compared
		# if a thread was started or the count changed, which also catches one
		# started with a Thread.new saved before Starting was prepended.
		if (started || threads.size != @threads.size) && threads != @threads
			(threads - @threads).each do |thread|
				location = started_at(thread) or next
				(leaks ||= []) << { "kind" => "thread", "message" => Quickdraw.utf8("A thread started at #{location} is still running.") }
			end

			@threads = threads
		end

		# Unsetting it would run its fibers to the end, which could take forever.
		scheduler = Fiber.scheduler

		unless scheduler.equal?(@scheduler)
			if scheduler
				message = Quickdraw.utf8("A fiber scheduler (#{scheduler.class}) was set and not unset, so later tests' fibers would run in it. Unset it with Fiber.set_scheduler(nil).")
				(leaks ||= []) << { "kind" => "scheduler", "message" => message }
			end

			@scheduler = scheduler
		end

		# Thread.list only has this Ractor's threads.
		ractors = ractor_count

		if ractors > @ractors
			(leaks ||= []) << { "kind" => "ractor", "message" => "#{ractors - @ractors} Ractor#{'s' if ractors - @ractors > 1} started here #{(ractors - @ractors > 1) ? 'are' : 'is'} still running." }
		end

		@ractors = ractors

		if started && (deaths = thread_deaths(started)).any?
			(leaks ||= []).concat(deaths)
		end

		if ENVChanges.changed
			ENVChanges.changed = false
			env = ENV.to_h

			if (change = env_change(env))
				(leaks ||= []) << { "kind" => "env", "message" => change }
			end

			@env = env
		end

		if (children = child_leaks)
			(leaks ||= []).concat(children)
		end

		leaks
	end

	# Child processes can only be told apart from those config or a test file
	# started when there were none before the test. After a leak, checking stops
	# until the leaked processes have exited, since one exiting later isn't the
	# next test's fault.
	private def child_leaks
		case @children
		in :unknown
			nil
		in :none
			return unless ProcessStarts.started

			ProcessStarts.started = false
			leaks = nil
			detached = settle_detached
			pid, status = wait_for_child

			while pid
				(leaks ||= []) << { "kind" => "process", "message" => "Child process #{pid} exited (#{status}), but wasn't waited for." } unless detached.key?(pid)
				pid, status = wait_for_child
			end

			if status == :running
				# One that Process.detach waits for is waited for. Not knowing
				# which are running, as when one has just exited, is only a leak
				# if none are detached.
				running = running_children.reject { |child_pid, _label| child_pid ? detached.key?(child_pid) : detached.any? }

				if running.any?
					@children = :leaked
					(leaks ||= []).concat(running.map { |_child_pid, label| { "kind" => "process", "message" => "Child process #{label} is still running." } })
				end

				# Until they've been reaped, checks wait for children, which the
				# worker must know so as not to charge their CPU to the next test.
				ProcessStarts.started = true
			end

			leaks
		in :leaked
			pid, status = wait_for_child
			pid, status = wait_for_child while pid

			if status == :none
				@children = :none
				ProcessStarts.started = false
			end

			nil
		end
	end

	# The pids of the children Process.detach's threads wait for, as { pid =>
	# true }, after giving them a moment to reap those that have just exited,
	# such as one a test killed, before this reaps them first.
	private def settle_detached
		waiters = Thread.list.select { |thread| Process::Waiter === thread && thread.alive? }
		return {} if waiters.empty?

		deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DETACH_GRACE
		waiters.each { |waiter| waiter.join((deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)).clamp(0, nil)) }
		waiters.to_h { |waiter| [waiter.pid, true] }
	end

	# [pid, status] for a child that has exited, which this reaps, or [nil,
	# :running] or [nil, :none].
	private def wait_for_child
		pid, status = Process.wait2(-1, Process::WNOHANG)
		pid ? [pid, status.exitstatus ? "status #{status.exitstatus}" : "signal #{status.termsig}"] : [nil, :running]
	rescue Errno::ECHILD
		[nil, :none]
	end

	# Running children as [pid, "pid (program)"], from ps, which is only run
	# once a leak is found, or [nil, "(unknown)"] if ps can't say. Not their
	# arguments, which can be secrets.
	private def running_children
		parent = Process.pid.to_s
		ps = nil
		table = IO.popen(["ps", "-A", "-o", "pid=,ppid=,comm="], err: File::NULL) do |io|
			ps = io.pid.to_s
			Quickdraw.utf8(io.read)
		end

		children = table.lines.filter_map do |line|
			pid, ppid, program = line.strip.split(" ", 3)
			[Integer(pid, 10), "#{pid} (#{File.basename(program.to_s)})"] if ppid == parent && pid != ps
		end

		children.empty? ? [[nil, "(unknown)"]] : children
	rescue SystemCallError
		[[nil, "(unknown)"]]
	end

	# Names only, since values can be secrets.
	private def env_change(env)
		added = env.keys - @env.keys
		removed = @env.keys - env.keys
		changed = env.keys.select { |name| @env.key?(name) && @env[name] != env[name] }
		return if added.empty? && removed.empty? && changed.empty?

		parts = [
			("added #{added.join(', ')}" if added.any?),
			("changed #{changed.join(', ')}" if changed.any?),
			("removed #{removed.join(', ')}" if removed.any?),
		].compact

		Quickdraw.utf8("ENV wasn't restored: #{parts.join('; ')}.")
	end

	# Where the thread's block is, relative to the project, or nil if that's
	# outside it.
	# Threads started since the last check that ended with an exception which
	# nothing joined them to see. A thread's status is nil once an exception has
	# ended it.
	private def thread_deaths(started)
		started.filter_map do |thread|
			next if thread.alive? || !thread.status.nil? || thread.quickdraw_joined?

			location = started_at(thread) or next
			error = begin
				thread.join
				nil
			rescue Exception => error
				error
			end

			{ "kind" => "thread", "message" => Quickdraw.utf8("A thread started at #{location} ended with #{error.class}: #{error.message}") } if error
		end
	end

	# Not on Rubies without Ractors.
	private def ractor_count = defined?(Ractor) ? Ractor.count : 1

	private def started_at(thread)
		# Without the name, which can contain anything, including spaces and colons.
		description = thread.inspect.sub(THREAD_ADDRESS, "")
		description = description.delete_prefix("@#{thread.name}") if thread.name
		match = THREAD_LOCATION.match(description) or return
		path = match[:path]
		"#{path.delete_prefix(@root)}:#{match[:line]}" if path.start_with?(@root) && !path.start_with?(@vendor) && !path.start_with?(@library)
	end
end
