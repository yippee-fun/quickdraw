# frozen_string_literal: true

# Watch mode's file watcher, which runs in a process of its own (see
# Watch#start_file_watcher), so Fiddle never loads where tests run. It watches
# the working directory, with FSEvents on macOS and inotify on Linux, or by
# polling elsewhere, and prints "ready", then each batch of changed files on a
# line, relative to the directory and separated by NUL. A directory stands for
# everything in it, when the watcher can't tell which files changed. Any line
# before "ready" is a warning for people.
module Quickdraw::FileWatcher
	extend self

	# Changes until none come for QUIET seconds, up to BATCH_LIMIT seconds
	# after the first, make one batch, such as an editor's atomic save or a git
	# checkout.
	QUIET = 0.02
	BATCH_LIMIT = 0.5

	# How often to check that Quickdraw is still running, in seconds.
	ORPHAN_CHECK = 1

	# Directories that are big, or that tools and tests write to, and never
	# hold what tests load.
	SKIPPED = %r{\A(?:\.quickdraw|tmp|log|vendor|coverage)/|(?:\A|/)(?:\.git|node_modules)/}

	# Files under `root` that changing doesn't report: those in SKIPPED, and
	# `paths`, which are relative. Directories end with a slash.
	Ignores = Data.define(:paths) do
		def ===(path) = SKIPPED.match?(path) || paths.include?(path)
	end

	# `ignored` are paths relative to the working directory, such as reports.
	# QUICKDRAW_POLL polls even where native events are available. If native
	# events stop being available, it polls from then on, says why on stderr,
	# and reports the root, since it can't tell what it missed.
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
				puts changes.uniq.join("\0")
			elsif Process.ppid != parent
				return
			end
		rescue Unavailable => error
			watcher = poll(root, ignores, error.message, $stderr)
			puts "."
		end
	rescue Errno::EPIPE
		nil
	end

	# Changes that arrive within ORPHAN_CHECK seconds, and those that follow
	# them until a quiet moment.
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

	# Yields the path relative to `root` and the File::Stat of everything in
	# `directory` (relative too, or nil for `root`) and below it that isn't
	# ignored, without following symlinks. What disappears meanwhile is skipped.
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

	# Native events can't be had, so the watcher polls instead.
	class Unavailable < StandardError; end
end
