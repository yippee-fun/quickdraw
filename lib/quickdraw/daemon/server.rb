# frozen_string_literal: true

# A project's daemon (see Daemon). It's a fork of a run that started cold, from
# before that run loaded anything but Quickdraw, so the loaders it forks, and
# the tests they run, see what a cold start's would. It keeps loaders booted
# (see WarmLoaders), and runs each request in a fork of itself, one at a time.
#
# It stops once it's been idle for a while, or when a run finds it out of
# date: Quickdraw, the bundle or the environment have changed. Loaders check
# what they booted from before every run (see Loader#check).
class Quickdraw::Daemon::Server
	# How long it stays with nothing to do, in seconds, unless QUICKDRAW_DAEMON_IDLE says.
	IDLE = 15 * 60

	REQUEST = /\A\d+-\h+\z/

	# What runs and their workers would otherwise load every time, which is
	# all a cold start's loader could have loaded already.
	PRELOADED = Quickdraw.deep_freeze(["CLI", "Commands", "Reporters", "Reporters::Human", "Reporters::StatusLine", "Reporters::Agent", "Reporters::LastRun", "Reporters::Multiple", "Reporters::GitHubActions", "Debugger", "Platform", "Profile", "Coordinator", "Coordinator::Retries", "Coordinator::Scheduler", "Coordinator::Flakes", "Filter", "Outcome", "History", "HistoryProcess", "Channel", "Loader", "WorkerTuner", "Worker", "Watchdog", "Capture", "Leaks", "Counters", "Timings", "Flake", "Test", "BasicTest", "Assertions", "Stubs", "Spy", "Timer", "Timer::Duration"])

	Request = Data.define(:directory, :program, :umask, :streams, :arguments, :environment)

	# In a run that's starting cold, before it loads anything else: leaves a
	# daemon for the runs after it, which starts booting once this one is done,
	# so they don't boot at once.
	def self.start
		run = Process.pid

		pid = Process.fork do
			Process.daemon(true)
			new(after: run).call
		end

		Process.wait(pid)
	end

	def initialize(after: nil, directory: Quickdraw::Daemon.directory)
		@after = after
		@directory = directory
		@environment = Quickdraw::Daemon.environment(ENV.to_h)
		@umask = File.umask
		# As they were when Bundler read them, in the run this forked from.
		gemfile = ENV["BUNDLE_GEMFILE"] || "Gemfile"
		lockfile = ENV["BUNDLE_LOCKFILE"] || "#{gemfile}.lock"
		@bundle = snapshot([gemfile, lockfile, "gems.rb", "gems.locked", ".ruby-version"].map { |path| File.expand_path(path, Quickdraw::ROOT) })
		@idle = Float(ENV.fetch("QUICKDRAW_DAEMON_IDLE", IDLE))
		@unread = +""
	end

	def call
		sleep 0.05 while @after && alive?(@after)
		return unless claim

		begin
			boot
			serve
		ensure
			stop
		end
	end

	# False if the project already has a daemon. Whatever one that was killed
	# left in the directory is removed.
	private def claim
		begin
			Dir.mkdir(@directory, 0o700)
		rescue Errno::EEXIST
			return false unless Quickdraw::Daemon.private?(@directory)
		end

		@lock = File.open(File.join(@directory, "lock"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
		return false unless @lock.flock(File::LOCK_EX | File::LOCK_NB)

		Dir.each_child(@directory) { |name| Quickdraw.remove_tree(File.join(@directory, name)) unless name == "lock" }
		File.write(File.join(@directory, "pid"), Process.pid.to_s)
		File.mkfifo(requests_path, 0o600)
		# For writing too, so it stays open between runs.
		@requests = File.open(requests_path, File::RDWR | File::NONBLOCK)
		true
	rescue SystemCallError
		false
	end

	private def boot
		log = File.join(@directory, "log")
		STDOUT.reopen(log, "a")
		STDERR.reopen(log, "a")
		STDOUT.sync = STDERR.sync = true
		Process.setproctitle("quickdraw daemon #{Quickdraw::ROOT}")
		# As the CLI does for a run, for every run this serves.
		ENV[Quickdraw::Debugger::FLAG] = File.join(Quickdraw.temporary_directory, "quickdraw-debugging-#{Process.pid}")

		# A run's Ctrl-C goes to this process's whole group (see Client), for the
		# run and its workers. Here, it only matters before the run has forked.
		@wake, @waker = IO.pipe

		trap("INT") do
			@interrupted = true
			@waker.write_nonblock(".", exception: false)
		end

		trap("TERM") do
			@terminated = true
			@waker.write_nonblock(".", exception: false)
		end

		@finished, @finish = IO.pipe
		PRELOADED.each { |name| Quickdraw.const_get(name) }
		# Loaders inherit these, so booting again wouldn't load them again.
		@loaded = snapshot(Quickdraw::WarmLoaders.loaded_files)

		@loaders = Quickdraw::WarmLoaders.new(coverage: false, test_output_to_stderr: false, directory: File.join(@directory, "sessions"), declines: true) do
			trap("INT") { nil }
			trap("TERM", "DEFAULT")
			disconnect
		end

		@loaders.refresh(interrupt: @wake)
	end

	private def serve
		expires_at = now + @idle

		until @stopping
			readable, = IO.select([@requests, @finished, @wake], nil, nil, (@running ? nil : (expires_at - now).clamp(0, nil)))
			break unless readable

			@wake.read_nonblock(64, exception: false) if readable.include?(@wake)
			break if @terminated

			if readable.include?(@finished)
				finish
				expires_at = now + @idle
			end

			next unless readable.include?(@requests)

			data = @requests.read_nonblock(4096, exception: false)
			@unread << data if String === data

			while (name = @unread.slice!(/\A.*\n/))
				take(name.chomp)
			end
		end
	end

	# Takes the request, unless the run has withdrawn it, or gone.
	private def take(name)
		return unless REQUEST.match?(name)

		directory = File.join(@directory, name)
		status = File.open(File.join(directory, "status"), File::WRONLY | File::NONBLOCK)
		status.sync = true
		File.rename(File.join(directory, "request"), File.join(directory, "accepted"))
		request = read(directory)

		answer = if @running then "busy"
		elsif fresh?(request) then run(request, status)
		else
			@stopping = true
			"stale"
		end

		if answer
			status.write("#{answer}\n")
			Quickdraw.remove_tree(directory)
		end
	rescue SystemCallError, ArgumentError, TypeError
		nil
	ensure
		status&.close
	end

	private def read(directory)
		program, umask, input, output, error, count, *rest = File.binread(File.join(directory, "accepted")).split("\0", -1)
		locale = Encoding.find("locale")
		arguments = rest.shift(Integer(count)).map { |argument| argument.force_encoding(locale) }
		environment = rest.to_h { |variable| variable.force_encoding(locale).split("=", 2) }
		streams = [input, output, error].map { |path| path unless path.empty? }

		Request.new(directory:, program:, umask: Integer(umask, 8), streams:, arguments:, environment:)
	end

	# Whether this process, and the loaders that fork from it, are what a cold
	# start would be now. Not if the project was replaced by another at the
	# same path, which this process isn't in.
	private def fresh?(request)
		Quickdraw::Daemon.environment(request.environment) == @environment && request.umask == @umask &&
			@bundle.changed.empty? && @loaded.changed.empty? && File.identical?(".", Quickdraw::ROOT)
	end

	# Starts the request's tests in a fork. Returns the answer, if there's
	# nothing to wait for.
	private def run(request, status)
		@interrupted = false
		# The leader of the process group that a run's Ctrl-C goes to.
		status.write("accepted #{Process.pid}\n")

		case plan(request)
		in Integer => exit_status
			return "exit #{exit_status}"
		in nil
			return "declined"
		in Hash => options
			nil
		end

		# Not before now, so what loaders don't run never waits for one to boot.
		refreshed = @loaders.refresh(interrupt: @wake)
		return "declined" if @terminated
		return "exit 130" if @interrupted || !refreshed

		@request = request
		@running = Process.fork { run_tests(request, options, status) }

		Thread.new(@running) do |pid|
			Process.wait(pid)
			@finish.write(".")
		end

		nil
	end

	# What the request asks for: a run's options, nil for what only a cold
	# start can do, or the exit status when there's nothing to run, as with
	# --help or a usage error. Worked out in a process that's thrown away,
	# since it loads what tests mustn't see, with the run's streams.
	private def plan(request)
		Quickdraw.isolate do
			trap("INT", "DEFAULT")
			become(request)
			Quickdraw::CLI.new(request.arguments).plan
		end
	rescue SystemExit => error
		@interrupted ? 130 : error.status
	end

	# In a fork: runs the request's tests as the CLI would have, and says how
	# it exited.
	private def run_tests(request, options, status)
		disconnect
		trap("INT", "DEFAULT")
		trap("TERM", "DEFAULT")
		become(request)
		@loaders.invocation = [request.streams, request.arguments, request.environment.slice(*Quickdraw::Daemon::VOLATILE)]

		run = Process.pid
		answer = "exit 1"

		# After any hooks the run adds. Not in the processes it forks.
		at_exit do
			if Process.pid == run
				flush(STDOUT)
				flush(STDERR)
				status.write("#{answer}\n")
			end
		end

		status.write("running #{run}\n")

		result = begin
			Quickdraw::CLI.new(request.arguments).serve(options, @loaders)
		rescue SystemExit => error
			error.status
		end

		answer = result ? "exit #{result}" : "declined"
		exit(result || 0)
	end

	# In a fork: takes on the streams and environment of the process that made
	# the request.
	private def become(request)
		Quickdraw::Daemon.redirect(request.streams)
		debugging = ENV[Quickdraw::Debugger::FLAG]
		ENV.replace(request.environment)
		ENV[Quickdraw::Debugger::FLAG] = debugging
		$PROGRAM_NAME = request.program
	end

	private def finish
		@finished.read_nonblock(16, exception: false)
		@running = nil
		@loaders.warm_up
		Quickdraw.remove_tree(@request.directory)
	end

	# Runs find no daemon as soon as it's stopping, though loaders can take a
	# while to exit.
	private def stop
		return unless @requests

		@requests.close
		File.delete(requests_path)
		@loaders&.stop
		Quickdraw.remove_tree(@directory)
	end

	# For processes forked from the daemon, which mustn't seem to be it.
	private def disconnect
		[@lock, @requests, @wake, @waker, @finished, @finish].each(&:close)
	end

	# The run's reader may have gone.
	private def flush(io)
		io.flush
	rescue SystemCallError
		nil
	end

	private def snapshot(paths) = Quickdraw::WarmLoaders::Snapshot.new(paths)

	private def requests_path = File.join(@directory, "requests")

	private def alive?(pid)
		Process.kill(0, pid)
		true
	rescue Errno::ESRCH
		false
	rescue Errno::EPERM
		true
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
