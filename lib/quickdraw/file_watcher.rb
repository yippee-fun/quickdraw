# frozen_string_literal: true

# Runs in its own process (see Watch.start_file_watcher), so Fiddle never
# loads where tests run. Prints any warnings, then "ready", then a line per
# batch of changed paths, relative and separated by NUL. A directory stands
# for everything in it.
module Quickdraw::FileWatcher
	extend self

	# A batch ends after QUIET seconds without changes, or BATCH_LIMIT seconds.
	QUIET = 0.02
	BATCH_LIMIT = 0.5
	ORPHAN_CHECK = 1

	SKIPPED = %r{\A(?:\.quickdraw|\.bundle|bundle|tmp|log|vendor|coverage)/|(?:\A|/)(?:\.git|\.svn|\.hg|\.rbx|node_modules)/}

	# Editors' and tools' scratch files, as listen ignored them.
	SCRATCH = /
		\A(?:\#.+\#|\.\#.+|4913|sed(?=[a-zA-Z0-9]{0,5}[A-Z])[a-zA-Z0-9]{6})\z
		| (?:\..*\d+\.new|\.kate-swp|\.goutputstream-.{6}|___jb_(?:bak|old)___|\.swpx|\.sw[px]|\.mutagen-temporary.*|\.DS_Store|\.tmp|~)\z
	/x

	# Directories end with a slash. Names needn't be valid UTF-8.
	Ignores = Data.define(:paths) do
		def ===(path)
			path = path.scrub
			SKIPPED.match?(path) || SCRATCH.match?(File.basename(path)) || paths.include?(path)
		end
	end

	def run(ignored)
		trap("TERM", "SYSTEM_DEFAULT")
		$stdout.sync = true
		root = File.realpath(Dir.pwd)
		ignores = Ignores.new(ignored)
		parent = Process.ppid
		watcher = start(root, ignores)
		puts "ready"

		loop do
			changes = batch(watcher)

			if changes.any?
				puts changes.map(&:scrub).uniq.join("\0")
			elsif Process.ppid != parent
				return
			end
		rescue Unavailable => error
			watcher = poll(root, ignores, error.message, $stderr)
			# What changed meanwhile is unknown.
			puts "."
		end
	rescue Errno::EPIPE
		nil
	end

	private def batch(watcher)
		changes = watcher.wait(ORPHAN_CHECK)
		return changes if changes.empty?

		deadline = now + BATCH_LIMIT

		while (remaining = deadline - now) > 0
			more = watcher.wait([QUIET, remaining].min)
			break if more.empty?

			changes.concat(more)
		end

		changes
	end

	# Yields each relative path and File::Stat under `directory` (or `root`)
	# that isn't ignored, without following symlinks.
	def each_entry(root, ignores, directory = nil, &block)
		Dir.each_child(directory ? File.join(root, directory) : root) do |name|
			relative = directory ? "#{directory}/#{name}" : name
			stat = lstat(File.join(root, relative))
			next if stat.nil? || ignores === (stat.directory? ? "#{relative}/" : relative)

			yield relative, stat
			each_entry(root, ignores, relative, &block) if stat.directory?
		end
	rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES
		nil
	end

	private def lstat(path)
		File.lstat(path)
	rescue Errno::ENOENT, Errno::EACCES
		nil
	end

	private def start(root, ignores)
		return poll(root, ignores, "QUICKDRAW_POLL is set") if ENV.key?("QUICKDRAW_POLL")

		case RUBY_PLATFORM
		in /darwin/
			require_relative "file_watcher/fs_events"
			FSEvents.new(root, ignores)
		in /linux/
			require_relative "file_watcher/inotify"
			Inotify.new(root, ignores)
		else
			poll(root, ignores, "#{RUBY_PLATFORM} has neither FSEvents nor inotify")
		end
	rescue LoadError => error
		poll(root, ignores, "Fiddle can’t be loaded (#{error.message})")
	rescue Unavailable => error
		poll(root, ignores, error.message)
	end

	private def poll(root, ignores, reason, out = $stdout)
		require_relative "file_watcher/polling"
		out.puts "Polling for changes every #{Polling::INTERVAL}s, since #{reason}."
		Polling.new(root, ignores)
	end

	private def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

	class Unavailable < StandardError; end
end
