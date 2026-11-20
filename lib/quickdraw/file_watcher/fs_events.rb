# frozen_string_literal: true

require "fiddle/import"

# Reports files under `root` as macOS changes them. FSEvents watches the whole
# tree without reading it first, and its file events name each file changed.
class Quickdraw::FileWatcher::FSEvents
	module CoreServices
		extend Fiddle::Importer

		dlload "/System/Library/Frameworks/CoreServices.framework/CoreServices"

		extern "void *CFStringCreateWithCString(void *, const char *, unsigned int)"
		extern "void *CFArrayCreate(void *, void *, long, void *)"
		extern "void *CFRunLoopGetCurrent()"
		extern "int CFRunLoopRunInMode(void *, double, unsigned char)"
		extern "void *FSEventStreamCreate(void *, void *, void *, void *, unsigned long long, double, unsigned int)"
		extern "void FSEventStreamScheduleWithRunLoop(void *, void *, void *)"
		extern "unsigned char FSEventStreamStart(void *)"

		def self.constant(name) = Fiddle::Pointer.new(handler.sym(name))
	end

	UTF8 = 0x0800_0100
	SINCE_NOW = 0xFFFF_FFFF_FFFF_FFFF
	LATENCY = 0.01
	NO_DEFER = 0x02
	FILE_EVENTS = 0x10
	FOREVER = 1e10

	MUST_SCAN_SUBDIRECTORIES = 0x1
	CREATED = 0x100
	REMOVED = 0x200
	METADATA_CHANGED = 0x400
	RENAMED = 0x800
	MODIFIED = 0x1000
	DIRECTORY = 0x20000
	CHANGED = CREATED | REMOVED | METADATA_CHANGED | RENAMED | MODIFIED

	def initialize(root, ignores)
		@prefix = "#{root}/"
		@ignores = ignores
		@changes = []
		# Kept, since FSEvents calls it for as long as the process runs.
		@callback = Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]) do |_stream, _info, count, paths, flags, _ids|
			record(count, paths, flags)
		end

		path = CoreServices.CFStringCreateWithCString(nil, root, UTF8)
		paths = CoreServices.CFArrayCreate(nil, [path.to_i].pack("J"), 1, CoreServices.constant("kCFTypeArrayCallBacks"))
		stream = CoreServices.FSEventStreamCreate(nil, @callback, nil, paths, SINCE_NOW, LATENCY, NO_DEFER | FILE_EVENTS)
		raise Quickdraw::FileWatcher::Unavailable, "FSEvents couldn’t watch #{root}" if stream.null?

		@mode = CoreServices.constant("kCFRunLoopDefaultMode").ptr
		CoreServices.FSEventStreamScheduleWithRunLoop(stream, CoreServices.CFRunLoopGetCurrent, @mode)
		raise Quickdraw::FileWatcher::Unavailable, "FSEvents couldn’t start" if CoreServices.FSEventStreamStart(stream) == 0
	end

	# Waits up to `timeout` seconds, or forever if nil, for changes, and
	# returns those since the last call. FSEvents calls back on this thread,
	# from within the run loop.
	def wait(timeout)
		CoreServices.CFRunLoopRunInMode(@mode, timeout || FOREVER, 1) if @changes.empty?
		@changes.slice!(0..)
	end

	private def record(count, paths, flags)
		addresses = paths[0, count * Fiddle::SIZEOF_VOIDP].unpack("J*")
		flags = flags[0, count * 4].unpack("L*")

		addresses.zip(flags) do |address, flag|
			next unless reported?(flag)

			path = Fiddle::Pointer.new(address).to_s.force_encoding(Encoding::UTF_8)
			relative = (path == @prefix.chomp("/")) ? "." : path.delete_prefix(@prefix)

			if flag.nobits?(DIRECTORY | MUST_SCAN_SUBDIRECTORIES)
				@changes << relative unless @ignores === relative
			elsif !(@ignores === "#{relative}/")
				@changes.concat(changes_in(relative, path))
			end
		end
	end

	# For a directory renamed, or under which FSEvents dropped events: the files
	# in it, which have no events of their own, or the directory if it's gone,
	# empty, or the root.
	private def changes_in(directory, path)
		files = []

		if File.directory?(path) && directory != "."
			Quickdraw::FileWatcher.each_entry(@prefix, @ignores, directory) { |file, stat| files << file unless stat.directory? }
		end

		files.empty? ? [directory] : files
	end

	# Directories only when renamed, or when FSEvents dropped events under them.
	private def reported?(flag)
		if flag.anybits?(MUST_SCAN_SUBDIRECTORIES)
			true
		elsif flag.anybits?(DIRECTORY)
			flag.anybits?(RENAMED)
		else
			flag.anybits?(CHANGED)
		end
	end
end
