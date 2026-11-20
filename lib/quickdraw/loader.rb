# frozen_string_literal: true

# Boots the shared test environment once, then forks workers.
class Quickdraw::Loader
	CONFIG_PATH = "config/quickdraw.rb"

	# How often workers are reaped while waiting for commands, in seconds.
	REAP_INTERVAL = 0.1

	# `channels` has one per possible worker, including spares. The coordinator
	# sends commands on `control`, one per line:
	#
	#   start COUNT          start workers on the first COUNT channels
	#   fork CHANNEL SLOT    start a worker on CHANNEL in SLOT
	#
	# A worker's slot is its QUICKDRAW_WORKER number, so a worker started in a
	# slot takes over the per-worker resources (such as a database) of the one
	# before it. When `control` closes, no more workers start. Without fork,
	# there's no `control`: see #call_in_thread.
	#
	# `group` names the group (see Configuration#group) whose tests this loader
	# runs, or is nil for tests in none. Once it has booted, the loader writes
	# to `report`, if given, a length-prefixed Marshal message: [:booted,
	# groups, coverage, settings] with the groups config defines as [name,
	# patterns, gemfile, cores, file_seconds], with `coverage`, what booting
	# covered (see CoverageCollector), and the run settings config set (see
	# Configuration#settings); or [:failed, error] if booting raised.
	#
	# `capture` and `leaks` are for workers (see Worker#initialize), or nil for
	# config to say. With `capture_loading`, what loading files prints goes to
	# the reporter.
	#
	# With a `link` instead (see WarmLoaders), the loader stays booted for
	# watch mode, and serves a run at a time, each with the commands, report
	# and channels above as named pipes in a directory, rather than once.
	def initialize(channels, test_files, seed, control: nil, test_output_to_stderr: false, profile: false, coverage: false, group: nil, report: nil, capture: false, capture_loading: false, leaks: nil, link: nil)
		@channels = channels
		@test_files = test_files
		@seed = seed
		@control = control
		@test_output_to_stderr = test_output_to_stderr
		@profile = profile
		@coverage = coverage
		@group = group
		@report = report
		@capture = capture
		@capture_loading = capture_loading
		@leaks = leaks
		@link = link
		@running = {}
		@statuses = []
	end

	# Starts a loader in a new process and returns its pid, taking the same
	# arguments as #initialize. It's a fork, which runs the block first, unless
	# there's a `gemfile`: then it's a new Ruby with that bundle, since Bundler
	# can't be unloaded, given its pipes as inherited file descriptors. `quiet`
	# discards its output.
	def self.start(channels, test_files, seed, gemfile: nil, quiet: false, **options)
		unless gemfile
			return Process.fork do
				yield if block_given?
				$stdout.reopen(File::NULL) if quiet
				$stderr.reopen(File::NULL) if quiet
				exit(new(channels, test_files, seed, **options).call)
			end
		end

		settings_reader, settings_writer = IO.pipe
		inherited = [settings_reader, options[:control], options[:report], *[*channels, options[:link]].compact.flat_map { |channel| [channel.reader, channel.writer] }].compact
		# Before Bundler starts, which can print.
		output = if quiet
			{ out: File::NULL, err: File::NULL }
		elsif options[:test_output_to_stderr]
			{ out: :err }
		else
			{}
		end

		# bundled_loader.rb sets the bundle up itself, so it can report a failure.
		rubyopt = ENV["RUBYOPT"]&.split&.grep_v(%r{\A-r\S*bundler/setup\z})&.join(" ")

		pid = Process.spawn(
			{ "BUNDLE_GEMFILE" => File.expand_path(gemfile), "BUNDLE_LOCKFILE" => nil, "BUNDLER_SETUP" => nil, "RUBYOPT" => rubyopt },
			RbConfig.ruby, File.join(Quickdraw::LIB, "quickdraw", "bundled_loader.rb"), settings_reader.fileno.to_s,
			**inherited.to_h { |io| [io, io] }, **output,
		)

		settings_reader.close

		begin
			settings_writer.write(Marshal.dump({
				channels: channels.map { |channel| [channel.reader.fileno, channel.writer.fileno] },
				test_files:,
				seed:,
				options: options.merge(
					control: options[:control]&.fileno,
					report: options[:report]&.fileno,
					link: options[:link]&.then { |link| [link.reader.fileno, link.writer.fileno] },
				),
			}))
		rescue Errno::EPIPE
			# Bundler failed, and said why. Without a report, the loader counts as
			# having exited while booting.
			nil
		ensure
			settings_writer.close
		end

		pid
	end

	# In a process from Loader.start, from the settings it wrote to `io`.
	def self.from_settings(io)
		settings = Marshal.load(io.read)
		io.close

		channels = settings.fetch(:channels).map { |reader, writer| Quickdraw::Channel.new(inherit(reader), inherit(writer, "w")) }
		options = settings.fetch(:options)
		options[:control] &&= inherit(options[:control])
		options[:report] &&= inherit(options[:report], "w")
		options[:link] &&= options[:link].then { |reader, writer| Quickdraw::Channel.new(inherit(reader), inherit(writer, "w")) }

		new(channels, settings.fetch(:test_files), settings.fetch(:seed), **options)
	end

	# Inherited without close-on-exec, which programs that tests run mustn't hold.
	private_class_method def self.inherit(fd, mode = "r")
		IO.new(fd, mode).tap { |io| io.close_on_exec = true }
	end

	# Reports that booting failed before #call, as #call does when it fails.
	def boot_failed(error)
		@boot_report = [:failed, Quickdraw.serialize_error(error)]
		@link ? serve_runs : report(@boot_report)
	end

	# Returns whether booting and every worker succeeded.
	def call
		# Before booting, so it covers what config prints, workers and processes
		# tests start, which all inherit it.
		$stdout.reopen($stderr) if @test_output_to_stderr

		# Ctrl-C reaches every process. The coordinator decides what happens, and
		# the loader waits for its workers to finish their teardown.
		trap("INT") { nil }

		Quickdraw::CoverageCollector.start if @coverage

		begin
			self.class.boot(group: @group)
		rescue Exception => error
			raise unless @report || @link

			boot_failed(error)
			return false
		end

		if @report || @link
			groups = Quickdraw::Config.groups.map { |group| [group.name, group.patterns, group.gemfile, group.cores, group.file_seconds] }
			@boot_report = [:booted, groups, (Quickdraw::CoverageCollector.take if @coverage), Quickdraw::Config.settings]
		end

		return serve_runs if @link

		report(@boot_report) if @report
		serve
	end

	# Starts workers as the coordinator asks, until it closes `control`.
	# Returns whether every worker succeeded.
	private def serve
		test_files = real_paths

		while @control
			reap

			if @control.wait_readable(REAP_INTERVAL)
				run_command(@control.gets&.split, test_files)
			end
		end

		# Blocking waits, so the loader exits as soon as the last worker does. The
		# coordinator has stopped checking liveness by now, so the order is fine.
		@running.each_key do |pid|
			@statuses << Process.wait2(pid).last.success?
		rescue Errno::ECHILD
			# Already reaped by a SIGCHLD handler that config installed.
			nil
		end

		@statuses.all?
	end

	# For a warm loader: answers the watch process about changes, and serves
	# runs, one at a time, until the watch process stops it, or exits.
	private def serve_runs
		@autoloadable = autoloadable_files

		while (message = @link.read)
			case message
			in [:changed, paths] then @link.write(refresh(paths))
			in [:run, directory] then serve_run(directory)
			in [:stop] then break
			end
		end

		true
	end

	# The run's settings and named pipes are in `directory` (see
	# WarmLoaders::Session). Writes whether every worker succeeded to its
	# `finished` pipe, closing which tells the run that the loader is done.
	# Skipped if the run has already gone, after Ctrl-C, say.
	private def serve_run(directory)
		settings = Marshal.load(File.binread(File.join(directory, "settings")))
		@test_files, @seed, @profile, @capture, @capture_loading, @leaks = settings.values_at(:test_files, :seed, :profile, :capture, :capture_loading, :leaks)
		@directory = directory
		@running = {}
		@statuses = []
		@control = open_pipe("control", File::RDONLY | File::NONBLOCK)
		@report = open_pipe("report", File::WRONLY | File::NONBLOCK)
		@finished = open_pipe("finished", File::WRONLY | File::NONBLOCK)

		report(@boot_report)
		success = @boot_report.first == :booted && serve
		@finished.write(success ? "1" : "0")
	rescue SystemCallError
		nil
	ensure
		[@control, @report, @finished].compact.each(&:close)
		@control = @report = @finished = @directory = nil
	end

	# What changes to `paths` (absolute) mean to a warm loader: :fresh if it
	# didn't load them, :reloaded if config's reloader reloaded them (see
	# Configuration#reloader), or :stale if it has to boot again.
	private def refresh(paths)
		return :stale unless @boot_report.first == :booted
		return :stale if paths.any? { |path| loaded_under?(path) }

		loaded = paths.select { |path| loaded?(path) }
		return :fresh if loaded.empty?
		return :stale unless Quickdraw::Config.reload(loaded)

		if @coverage
			# Taken, so workers don't inherit it, in place of what loading the
			# reloaded files' old versions covered. Other files have zero counts.
			reloaded = Quickdraw::CoverageCollector.take
			@boot_report[2].merge!(reloaded.slice(*Quickdraw::CoverageCollector.run(reloaded)))
		end

		@autoloadable = autoloadable_files
		:reloaded
	rescue StandardError, ScriptError
		# Booting again reports what's wrong.
		:stale
	end

	# Whether booting loaded `path`, or the autoloader's idea of it is out of
	# date, since it's been added or deleted.
	private def loaded?(path)
		path = File.realpath(path) if File.exist?(path)
		return true if $LOADED_FEATURES.include?(path)

		autoloadable = path.end_with?(".rb") && autoload_dirs.any? { |dir| path.start_with?("#{dir}/") }
		autoloadable && File.exist?(path) != @autoloadable.key?(path)
	end

	# Whether `path` is a directory, perhaps moved away or deleted, holding
	# something booting loaded or the autoloader knows. FileWatcher reports a
	# directory when it can't say which files in it changed, which only booting
	# again is sure to cover.
	private def loaded_under?(path)
		return false if File.file?(path)

		directory = "#{File.exist?(path) ? File.realpath(path) : path}/"
		$LOADED_FEATURES.any? { |feature| feature.start_with?(directory) } || @autoloadable.each_key.any? { |file| file.start_with?(directory) }
	end

	private def autoloadable_files
		autoload_dirs.flat_map { |dir| Dir.glob("**/*.rb", base: dir).map { |path| File.join(dir, path) } }.to_h { |path| [path, true] }
	end

	# Zeitwerk's, if config loaded it.
	private def autoload_dirs
		defined?(::Zeitwerk::Loader) ? ::Zeitwerk::Loader.all_dirs : []
	end

	# Used where fork isn’t available: a single worker in a thread of this process.
	# Tests then share a process with the coordinator, so they can see what it
	# loads (sqlite3 and json for run history), and every group's setup runs.
	def call_in_thread
		Thread.new do
			channel = @channels.fetch(0)
			self.class.boot
			Quickdraw::Config.groups.each { |group| group.setup&.call }
			start_worker(channel, 0, real_paths, timeouts: false)
		ensure
			channel.close
		end
	end

	private def run_command(command, test_files)
		case command
		in nil
			@control.close
			@control = nil
			@channels.each(&:close)
		in ["start", count]
			Integer(count).clamp(0, @channels.size).times { |index| start(index, index, test_files) }
		in ["fork", channel, slot]
			start(Integer(channel), Integer(slot), test_files)
		in ["flakes", size]
			report_flakes(@control.read(Integer(size)))
		end
	end

	# Passes each of a run's flakes (see Flake.report) to config's on_flaky
	# callbacks. One that raises is shown, and doesn't stop the others.
	private def report_flakes(json)
		require "json"
		data = JSON.parse(json)
		flakes = data.fetch("flakes").map { |entry| Quickdraw::Flake.from(entry, data) }

		Quickdraw::Config.flaky_callbacks.product(flakes) do |callback, flake|
			callback.call(flake)
		rescue StandardError, ScriptError => error
			frames = error.backtrace&.first(5)&.map { |frame| "\n  #{frame}" }&.join
			warn "config.on_flaky raised #{error.class}: #{error.message}, reporting #{flake.path}:#{flake.line}#{frames}"
		end
	end

	private def start(channel_index, slot, test_files)
		channel = open_channel(channel_index)

		pid = Process.fork do
			# A handler rather than "IGNORE", which processes that tests exec would
			# inherit. While a debugger has the terminal, Ctrl-C is its, as usual.
			trap("INT") do
				if Quickdraw::Debugger.holding? then raise Interrupt
				elsif !Quickdraw::Debugger.active? then raise Quickdraw::Interrupted
				end
			end
			@control.close
			@channels.each { |other| other.close unless other.equal?(channel) }
			# Only the loader holds these, so closing them says it's done.
			@link&.close
			@finished&.close
			start_worker(channel, slot, test_files)
		end

		@running[pid] = true
	rescue SystemCallError => error
		# e.g. EAGAIN at the process limit. Closing the channel tells the
		# coordinator this worker is gone.
		warn "Quickdraw couldn’t start a worker: #{error.message}"
		@statuses << false
	ensure
		# The worker has its own copy. Closing ours means its exit closes the pipes.
		channel&.close
	end

	# In a warm loader's run, the named pipes the run made for the channel.
	private def open_channel(index)
		return @channels.fetch(index) unless @directory

		Quickdraw::Channel.new(open_pipe("#{index}.down", File::RDONLY | File::NONBLOCK), open_pipe("#{index}.up", File::WRONLY | File::NONBLOCK))
	end

	# Binary, since Marshal data can't be transcoded, as it would be if config
	# sets Encoding.default_internal (Rails does).
	private def open_pipe(name, flags)
		File.open(File.join(@directory, name), flags, binmode: true)
	end

	# Only this loader's workers, not processes that config may have started.
	# Reaped promptly so the coordinator's liveness check sees them go.
	private def reap
		@running.keys.each do |pid|
			_, status = Process.wait2(pid, Process::WNOHANG)

			if status
				@running.delete(pid)
				@statuses << status.success?
			end
		rescue Errno::ECHILD
			# Already reaped by a SIGCHLD handler that config installed.
			@running.delete(pid)
		end
	end

	# Loads config and runs its before_forking callbacks, then the setup of
	# `group`, if given. Every process that runs tests forks from one that has
	# done this.
	def self.boot(group: nil)
		require File.expand_path(CONFIG_PATH) if File.exist?(CONFIG_PATH)
		Quickdraw::Config.before_forking_callbacks.each(&:call)

		if group
			definition = Quickdraw::Config.groups.find { |it| it.name == group }
			raise "There’s no #{group} group in #{CONFIG_PATH}." unless definition

			definition.setup&.call
		end

		Process.warmup if Process.respond_to?(:warmup)
	end

	# Closed afterwards, so workers, which fork later, don't hold it open.
	private def report(message)
		data = Marshal.dump(message)
		@report.write([data.bytesize].pack("N"), data)
		@report.close
	rescue Errno::EPIPE
		nil
	end

	# Keyed by both expanded and real paths, since `require` may resolve symlinks.
	private def real_paths
		@test_files.flat_map { |path| [File.expand_path(path), File.realpath(path)] }.to_h { |path| [path, true] }
	end

	private def start_worker(channel, index, test_files, timeouts: true)
		# Before the callbacks, so the coordinator can tell if this process dies
		# even while a child the callbacks started holds the channel open.
		channel.write([:pid, Process.pid])

		# Unbuffered, so what a test prints shows up while it runs, even if it hangs.
		$stdout.sync = true
		$stderr.sync = true

		ENV["QUICKDRAW_WORKER"] = index.to_s
		ENV["TEST_ENV_NUMBER"] = (index == 0) ? "" : (index + 1).to_s
		# Before the callbacks, so processes they start aren't blamed on tests.
		Quickdraw::Leaks::ProcessStarts.watch if leaks
		Quickdraw::Config.after_forking_callbacks.each(&:call)
		Quickdraw::Worker.new(channel, test_files, @seed, timeouts:, profile: @profile, coverage: @coverage, capture:, leaks:).call
	end

	# Whether workers capture what tests print, as the run said or else config
	# (see Configuration#settings), and with :loading, what loading files
	# prints too, for the reporter.
	private def capture
		capture = @capture.nil? ? Quickdraw::Config.settings.fetch(:capture, true) : @capture
		(capture && @capture_loading) ? :loading : capture
	end

	# :warn, :fail, or nil for off, as the run said or else config.
	private def leaks
		mode = @leaks || Quickdraw::Config.settings.fetch(:leaks, :warn)
		mode unless mode == :off
	end
end
