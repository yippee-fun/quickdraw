# frozen_string_literal: true

# Watch mode's loaders (see Loader), which stay booted between runs, so only
# the first run waits for config to boot. They fork from the watch process,
# which is as clean as the runs it forks, and each serves one run at a time
# through a Session.
#
# A run happens in a fork of the watch process, so it can't give a loader that
# already exists new pipes: passing them needs a UNIX socket, and loaders
# mustn't load socket, which tests would see. Instead, the run makes named
# pipes for the loader and its workers to open.
class Quickdraw::WarmLoaders
	# Changes that need every loader booted again: config, Rails' included, and
	# the bundle.
	REBOOT = %r{\Aconfig/|(?:\A|/)(?:Gemfile|gems\.rb)(?:\.lock|\.locked)?\z|\.gemfile(?:\.lock)?\z|\A\.ruby-version\z}

	# How long loaders have to exit by themselves when watch mode stops, in seconds.
	EXIT_GRACE = 3

	# `link` is a Channel to the loader (see Loader#serve_runs), and `waiter`
	# reaps it, so a run can tell it's gone.
	Loader = Data.define(:pid, :link, :waiter, :gemfile)

	# A run's use of a warm loader, in place of the loader process the
	# coordinator would start. Its control, report and channels are named
	# pipes in `directory`, which the loader opens, and the loader is done
	# with the run once it writes whether its workers succeeded to `finished`,
	# or exits.
	class Session < Quickdraw::Coordinator::LoaderProcess
		Finished = Data.define(:success) do
			def success? = success
		end

		# `settings` are for workers (see Loader#serve_run).
		def initialize(pid, directory, group:, capacity:, settings:)
			Dir.mkdir(directory, 0o700)
			File.binwrite(File.join(directory, "settings"), Marshal.dump(settings))
			@directory = directory
			@finished = fifo("finished", File::RDONLY | File::NONBLOCK)
			# Opened for reading too, so it doesn't wait for the loader, which
			# sees the end once this process closes it.
			control = fifo("control", File::RDWR).tap { |io| io.sync = true }
			report = fifo("report", File::RDONLY | File::NONBLOCK)

			channels = Array.new(capacity) do |index|
				Quickdraw::Channel.new(fifo("#{index}.up", File::RDONLY | File::NONBLOCK), fifo("#{index}.down", File::RDWR))
			end

			super(group:, pid:, control:, report:, channels:)
		end

		# Checked before `finished`, since the loader may write to it and exit in between.
		def status
			return @status if @status

			exited = !loader_alive?

			@status = if @finished.wait_readable(0)
				Finished.new(@finished.read(1) == "1")
			elsif exited
				Finished.new(false)
			end
		end

		# Checking often at first, since loaders usually finish within a few milliseconds.
		def wait
			delay = 0.0005

			until status
				sleep delay
				delay = [delay * 2, 0.01].min
			end

			status
		end

		private def loader_alive?
			Process.kill(0, @pid)
			true
		rescue Errno::ESRCH
			false
		end

		private def fifo(name, flags)
			path = File.join(@directory, name)
			File.mkfifo(path, 0o600)
			File.open(path, flags, binmode: true)
		end
	end

	# `coverage` and `test_output_to_stderr` are as for Loader#initialize, and
	# the same for every run.
	def initialize(coverage:, test_output_to_stderr:)
		@coverage = coverage
		@test_output_to_stderr = test_output_to_stderr
		@directory = File.join(ENV.fetch("TMPDIR", "/tmp"), "quickdraw-#{Random.urandom(8).unpack1('H*')}")
		Dir.mkdir(@directory, 0o700)
		@loaders = {}
		@wanted = Quickdraw::Channel.new(*IO.pipe)
		@sessions = 0
	end

	# In the watch process, before a run: replaces loaders that have exited, or
	# that `changed` (paths relative to the project) left stale, and starts the
	# loader for tests in no group. Returns false, without starting anything,
	# if `interrupt` becomes readable while loaders are answering.
	def prepare(changed, interrupt:)
		paths = changed.map { |path| File.expand_path(path) }
		everything = changed.any? { |path| REBOOT.match?(path) }

		stale = @loaders.select do |_group, loader|
			everything || !loader.waiter.alive? || (loader.gemfile && paths.intersect?(bundle_files(loader.gemfile)))
		end

		stale.each_key { |group| restart(group) }
		return false unless ask(paths, @loaders.except(*stale.keys), interrupt)

		@loaders[nil] ||= start(nil, nil)
		true
	end

	# In the watch process, after a run: starts the loaders it wanted, for the
	# next run, and removes its named pipes.
	def warm_up
		while @wanted.reader.wait_readable(0)
			group, gemfile = @wanted.read

			if @loaders.key?(group)
				restart(group, gemfile)
			else
				@loaders[group] = start(group, gemfile)
			end
		end

		remove_sessions
	end

	# In a run: a session with the warm loader for `group`, or nil if there
	# isn't one with `gemfile` yet, in which case one starts after the run.
	# `capacity` is the number of channels; the rest is as for Loader#initialize.
	def session(group, gemfile:, capacity:, coverage:, test_output_to_stderr:, **settings)
		unless coverage == @coverage && test_output_to_stderr == @test_output_to_stderr
			raise ArgumentError, "Warm loaders were started with coverage: #{@coverage}, test_output_to_stderr: #{@test_output_to_stderr}."
		end

		loader = @loaders[group]

		unless loader && loader.gemfile == gemfile
			@wanted.write([group, gemfile])
			return
		end

		directory = File.join(@directory, "#{Process.pid}-#{@sessions += 1}")
		session = Session.new(loader.pid, directory, group:, capacity:, settings:)
		return session if loader.link.write([:run, directory])

		# It has exited, and prepare replaces it before the next run.
		session.close
		nil
	end

	# For processes a run forks, which mustn't hold the loaders' links.
	def disconnect
		@loaders.each_value { |loader| loader.link.close }
		@wanted.close
	end

	# Stops every loader, killing those that don't exit within EXIT_GRACE.
	def stop
		@loaders.each_value { |loader| dismiss(loader) }
		deadline = now + EXIT_GRACE
		@loaders.each_value { |loader| wait_for_exit(loader, deadline) }
		@loaders.clear
		remove_sessions
		Dir.rmdir(@directory)
	end

	# Asks `loaders` what `paths` (absolute) changing means for them, and
	# replaces those that need booting again, or that exit meanwhile, since a
	# process config started can hold their link open. Returns false if
	# interrupted.
	private def ask(paths, loaders, interrupt)
		return true if paths.empty?

		asking = {}

		loaders.each do |group, loader|
			if loader.link.write([:changed, paths])
				asking[loader.link.reader] = group
			else
				restart(group)
			end
		end

		until asking.empty?
			readable, = IO.select([*asking.keys, interrupt], nil, nil, 0.1)
			return false if readable&.include?(interrupt)

			asking.to_a.each do |reader, group|
				if readable&.include?(reader)
					asking.delete(reader)
					restart(group) unless @loaders.fetch(group).link.read in :fresh | :reloaded
				elsif !@loaders.fetch(group).waiter.alive?
					asking.delete(reader)
					restart(group)
				end
			end
		end

		true
	end

	private def start(group, gemfile)
		link, loader_link = Quickdraw::Channel.pair

		pid = Quickdraw::Loader.start([], [], nil, gemfile:, link: loader_link, group:, coverage: @coverage, test_output_to_stderr: @test_output_to_stderr) do
			link.close
			disconnect
		end

		loader_link.close
		Loader.new(pid:, link:, waiter: Process.detach(pid), gemfile:)
	end

	# Not until the old loader has exited, since its at_exit hooks may still be
	# using what the new one needs, such as a port.
	private def restart(group, gemfile = @loaders.fetch(group).gemfile)
		loader = @loaders.fetch(group)
		dismiss(loader)
		wait_for_exit(loader, now + EXIT_GRACE)
		@loaders[group] = start(group, gemfile)
	end

	# Asks the loader to exit once it has finished any run. Closing the link
	# isn't enough, since processes a run forked can hold it open.
	private def dismiss(loader)
		loader.link.write([:stop])
		loader.link.close
	end

	# Kills the loader if it hasn't exited by `deadline`.
	private def wait_for_exit(loader, deadline)
		return if loader.waiter.join((deadline - now).clamp(0, nil))

		begin
			Process.kill("KILL", loader.pid)
		rescue Errno::ESRCH
			nil
		end

		loader.waiter.join
	end

	# A Gemfile and its lockfile, as Bundler names it.
	private def bundle_files(gemfile)
		[gemfile, "#{gemfile}.lock", "#{gemfile.delete_suffix('.rb')}.locked"]
	end

	private def remove_sessions
		Dir.each_child(@directory) do |name|
			session = File.join(@directory, name)
			Dir.each_child(session) { |file| File.unlink(File.join(session, file)) }
			Dir.rmdir(session)
		end
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
