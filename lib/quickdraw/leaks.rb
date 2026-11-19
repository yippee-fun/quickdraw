# frozen_string_literal: true

# Finds state a test left behind, after every test: threads it started that are
# still running, child processes it didn't wait for, and changes to ENV. Unless
# a test changed ENV or started a process, this only compares the thread list.
#
# Runs in the worker alongside user code, so it must only use core Ruby.
class Quickdraw::Leaks
	# Thread#inspect is "#<Thread:0x…@name path:line status>".
	THREAD_ADDRESS = /\A#<Thread:0x\h+/
	THREAD_LOCATION = /\A (?<path>.+):(?<line>\d+) \w+>\z/m

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

	# Threads are only reported if they started in `root`, outside vendor/, so
	# the threads libraries start for themselves (Timeout's, connection pool
	# reapers) aren't blamed on the first test to use them.
	def initialize(root)
		@root = "#{root}/"
		@vendor = "#{root}/vendor/"
		@library = "#{Quickdraw::LIB}/"
		ENV.singleton_class.prepend(ENVChanges)
		raise "ProcessStarts.watch must be called before after_forking callbacks." unless ProcessStarts.watching?
		# Not by waiting, which would reap a process config started and will wait for.
		@children = ProcessStarts.started ? :unknown : :none
		ProcessStarts.started = false
		reset
	end

	# What's there now is the starting point, e.g. after loading a file.
	def reset
		@threads = Thread.list
		@env = ENV.to_h
		ENVChanges.changed = false
		# A test file can start processes as it loads, which aren't its tests' leaks.
		@children = :unknown if ProcessStarts.started && @children == :none
		ProcessStarts.started = false
	end

	# Leaks since the last check or reset, as [{ "kind" =>, "message" => }], or nil.
	def check
		leaks = nil
		threads = Thread.list

		unless threads == @threads
			(threads - @threads).each do |thread|
				location = started_at(thread) or next
				(leaks ||= []) << { "kind" => "thread", "message" => Quickdraw.utf8("A thread started at #{location} is still running.") }
			end

			@threads = threads
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
			pid, status = wait_for_child

			while pid
				(leaks ||= []) << { "kind" => "process", "message" => "Child process #{pid} exited (#{status}), but wasn't waited for." }
				pid, status = wait_for_child
			end

			if status == :running
				@children = :leaked
				(leaks ||= []).concat(running_children.map { |child| { "kind" => "process", "message" => "Child process #{child} is still running." } })
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

	# [pid, status] for a child that has exited, which this reaps, or [nil,
	# :running] or [nil, :none].
	private def wait_for_child
		pid, status = Process.wait2(-1, Process::WNOHANG)
		pid ? [pid, status.exitstatus ? "status #{status.exitstatus}" : "signal #{status.termsig}"] : [nil, :running]
	rescue Errno::ECHILD
		[nil, :none]
	end

	# Running children's pids and programs, from ps, which is only run once a
	# leak is found. Not their arguments, which can be secrets.
	private def running_children
		parent = Process.pid.to_s
		ps = nil
		table = IO.popen(["ps", "-A", "-o", "pid=,ppid=,comm="], err: File::NULL) do |io|
			ps = io.pid.to_s
			Quickdraw.utf8(io.read)
		end

		children = table.lines.filter_map do |line|
			pid, ppid, program = line.strip.split(" ", 3)
			"#{pid} (#{File.basename(program.to_s)})" if ppid == parent && pid != ps
		end

		children.empty? ? ["(unknown)"] : children
	rescue SystemCallError
		["(unknown)"]
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
	private def started_at(thread)
		# Without the name, which can contain anything, including spaces and colons.
		description = thread.inspect.sub(THREAD_ADDRESS, "")
		description = description.delete_prefix("@#{thread.name}") if thread.name
		match = THREAD_LOCATION.match(description) or return
		path = match[:path]
		"#{path.delete_prefix(@root)}:#{match[:line]}" if path.start_with?(@root) && !path.start_with?(@vendor) && !path.start_with?(@library)
	end
end
