# frozen_string_literal: true

require "fiddle/import"

class Quickdraw::FileWatcher::Inotify
	module LibC
		extend Fiddle::Importer

		dlload Fiddle::Handle::DEFAULT

		extern "int inotify_init1(int)"
		extern "int inotify_add_watch(int, const char *, unsigned int)"
		extern "int inotify_rm_watch(int, int)"
	end

	NONBLOCK = 0o4000
	CLOSE_ON_EXEC = 0o2000000

	MODIFY = 0x2
	ATTRIBUTES_CHANGED = 0x4
	CLOSE_WRITE = 0x8
	MOVED_FROM = 0x40
	MOVED_TO = 0x80
	CREATE = 0x100
	DELETE = 0x200
	DELETE_SELF = 0x400
	MOVE_SELF = 0x800
	OVERFLOWED = 0x4000
	REMOVED = 0x8000
	ONLY_DIRECTORY = 0x0100_0000
	DONT_FOLLOW = 0x0200_0000
	EXCLUDE_UNLINKED = 0x0400_0000
	DIRECTORY = 0x4000_0000
	MASK = MODIFY | ATTRIBUTES_CHANGED | CLOSE_WRITE | MOVED_FROM | MOVED_TO | CREATE | DELETE | DELETE_SELF | MOVE_SELF | ONLY_DIRECTORY | DONT_FOLLOW | EXCLUDE_UNLINKED

	# struct inotify_event: watch, mask, cookie and name length, then the
	# NUL-padded name. A read never splits an event.
	EVENT = "lLLL"
	EVENT_SIZE = 16
	READ_SIZE = 64 * 1024

	def initialize(root, ignores)
		@root = root
		@ignores = ignores
		start
	end

	def wait(timeout)
		return [] unless @io.wait_readable(timeout)

		events = @io.read_nonblock(READ_SIZE, exception: false)
		return [] if events == :wait_readable

		changes = []
		offset = 0

		while offset < events.bytesize
			watch, mask, _cookie, length = events.unpack(EVENT, offset:)

			# Events were dropped, so watches may be missing or stale.
			if mask.anybits?(OVERFLOWED)
				@io.close
				start
				return ["."]
			end

			name = events.byteslice(offset + EVENT_SIZE, length).unpack1("Z*").force_encoding(Encoding::UTF_8)
			offset += EVENT_SIZE + length
			changes.concat(changed(watch, mask, name))
		end

		changes
	rescue Quickdraw::FileWatcher::Unavailable
		@io.close
		raise
	end

	private def start
		descriptor = LibC.inotify_init1(NONBLOCK | CLOSE_ON_EXEC)
		raise Quickdraw::FileWatcher::Unavailable, "inotify couldn’t start (#{SystemCallError.new(nil, Fiddle.last_error).message})" if descriptor < 0

		@io = IO.for_fd(descriptor, "rb")
		@directories = {}
		watch_new(nil)
	rescue Quickdraw::FileWatcher::Unavailable
		@io&.close
		raise
	end

	private def changed(watch, mask, name)
		return [] unless @directories.key?(watch)

		if mask.anybits?(REMOVED)
			@directories.delete(watch)
			return []
		end

		# Events on the watched directory itself, which its parent reports too.
		return [] if name.empty?

		directory = @directories.fetch(watch)
		path = directory ? "#{directory}/#{name}" : name

		if mask.nobits?(DIRECTORY)
			(@ignores === path) ? [] : [path]
		elsif @ignores === "#{path}/"
			[]
		elsif mask.anybits?(CREATE | MOVED_TO)
			# Its files may predate its watch, and a moved one's have no events.
			watch_new(path)
		elsif mask.anybits?(MOVED_FROM)
			forget(path)
			[path]
		else
			[]
		end
	end

	private def watch(directory)
		path = directory ? File.join(@root, directory) : @root
		watch = LibC.inotify_add_watch(@io.fileno, path, MASK)
		return @directories[watch] = directory if watch >= 0

		case Fiddle.last_error
		in Errno::ENOSPC::Errno
			raise Quickdraw::FileWatcher::Unavailable, "inotify can’t watch more directories (see fs.inotify.max_user_watches)"
		in Errno::ENOENT::Errno | Errno::ENOTDIR::Errno | Errno::EACCES::Errno
			nil
		in error
			raise SystemCallError.new(path, error)
		end
	end

	# Watches `directory` (or the root) and those in it, and returns its files.
	private def watch_new(directory)
		files = []
		watch(directory)

		Quickdraw::FileWatcher.each_entry(@root, @ignores, directory) do |path, stat|
			stat.directory? ? watch(path) : files << path
		end

		files
	end

	# A moved directory's watches follow it, so they're replaced if it's still here.
	private def forget(directory)
		@directories.each do |watch, path|
			LibC.inotify_rm_watch(@io.fileno, watch) if path == directory || path&.start_with?("#{directory}/")
		end
	end
end
