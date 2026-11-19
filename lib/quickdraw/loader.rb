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
	# groups] with the groups config defines as [name, patterns] pairs, or
	# [:failed, error] if booting raised.
	def initialize(channels, test_files, seed, control: nil, test_output_to_stderr: false, profile: false, group: nil, report: nil)
		@channels = channels
		@test_files = test_files
		@seed = seed
		@control = control
		@test_output_to_stderr = test_output_to_stderr
		@profile = profile
		@group = group
		@report = report
		@running = {}
		@statuses = []
	end

	# Returns whether booting and every worker succeeded.
	def call
		# Before booting, so it covers what config prints, workers and processes
		# tests start, which all inherit it.
		$stdout.reopen($stderr) if @test_output_to_stderr

		# Ctrl-C reaches every process. The coordinator decides what happens, and
		# the loader waits for its workers to finish their teardown.
		trap("INT") { nil }

		begin
			self.class.boot(group: @group)
		rescue Exception => error
			raise unless @report

			report([:failed, Quickdraw.serialize_error(error)])
			return false
		end

		report([:booted, Quickdraw::Config.groups.map { |group| [group.name, group.patterns] }]) if @report
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
		end
	end

	private def start(channel_index, slot, test_files)
		channel = @channels.fetch(channel_index)

		pid = Process.fork do
			# A handler rather than "IGNORE", which processes that tests exec would inherit.
			trap("INT") { raise Quickdraw::Interrupted }
			@control.close
			@channels.each { |other| other.close unless other.equal?(channel) }
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
		Quickdraw::Config.after_forking_callbacks.each(&:call)
		Quickdraw::Worker.new(channel, test_files, @seed, timeouts:, profile: @profile).call
	end
end
