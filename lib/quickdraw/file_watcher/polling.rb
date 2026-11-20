# frozen_string_literal: true

# Reports files under `root` that appear, disappear or change, by comparing
# what File.lstat says of each every INTERVAL seconds.
class Quickdraw::FileWatcher::Polling
	INTERVAL = 0.5

	def initialize(root, ignores)
		@root = root
		@ignores = ignores
		@files = snapshot
		@next_scan = now + INTERVAL
	end

	# Waits up to `timeout` seconds, or forever if nil, for changes, and
	# returns those since the last call.
	def wait(timeout)
		delay = @next_scan - now

		if timeout && timeout < delay
			sleep timeout
			return []
		end

		sleep delay if delay > 0
		@next_scan = now + INTERVAL
		previous, @files = @files, snapshot
		(previous.keys | @files.keys).reject { |path| previous[path] == @files[path] }
	end

	private def snapshot
		files = {}

		Quickdraw::FileWatcher.each_entry(@root, @ignores) do |path, stat|
			files[path] = [stat.mtime, stat.size, stat.ino, stat.mode] unless stat.directory?
		end

		files
	end

	private def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
