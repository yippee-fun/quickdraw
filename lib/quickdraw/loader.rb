# frozen_string_literal: true

# Boots the shared test environment once, then forks workers.
class Quickdraw::Loader
	CONFIG_PATH = "config/quickdraw.rb"

	# `channels` has one per possible worker. `control` is read for how many to
	# start, which the coordinator decides while this boots.
	def initialize(channels, test_files, seed, control: nil)
		@channels = channels
		@test_files = test_files
		@seed = seed
		@control = control
	end

	# Returns whether booting and every worker succeeded.
	def call
		boot
		test_files = real_paths

		count = @control ? @control.gets.to_i.clamp(0, @channels.size) : @channels.size
		@control&.close
		workers = @channels.first(count)

		workers.each_with_index do |channel, index|
			Process.fork do
				@channels.each { |other| other.close unless other.equal?(channel) }
				start_worker(channel, index, test_files)
			end
		end

		@channels.each(&:close)

		# Reap workers as they exit, so the coordinator's liveness check sees them go.
		Process.waitall.all? { |_pid, status| status.success? }
	end

	# Used where fork isn’t available: a single worker in a thread of this process.
	# Tests then share a process with the coordinator, so they can see what it
	# loads (sqlite3 and json for run history).
	def call_in_thread
		Thread.new do
			channel = @channels.fetch(0)
			boot
			start_worker(channel, 0, real_paths)
		ensure
			channel.close
		end
	end

	private def boot
		require File.expand_path(CONFIG_PATH) if File.exist?(CONFIG_PATH)
		Quickdraw::Config.before_forking_callbacks.each(&:call)
		Process.warmup if Process.respond_to?(:warmup)
	end

	# Keyed by both expanded and real paths, since `require` may resolve symlinks.
	private def real_paths
		@test_files.flat_map { |path| [File.expand_path(path), File.realpath(path)] }.to_h { |path| [path, true] }
	end

	private def start_worker(channel, index, test_files)
		ENV["QUICKDRAW_WORKER"] = index.to_s
		ENV["TEST_ENV_NUMBER"] = (index == 0) ? "" : (index + 1).to_s
		Quickdraw::Config.after_forking_callbacks.each(&:call)
		Quickdraw::Worker.new(channel, test_files, @seed).call
	end
end
