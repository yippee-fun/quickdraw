# frozen_string_literal: true

# Captures what tests print by pointing the worker's stdout and stderr file
# descriptors at a file, so it includes what subprocesses and C extensions
# print. Both streams go to the same file, keeping them in order. The file has a
# path so the coordinator can read it if the worker dies mid-test.
#
# Runs in the worker alongside user code, so it must only use core Ruby.
class Quickdraw::Capture
	# Longer output keeps only its end, which is nearest the failure.
	LIMIT = 64 * 1024

	# What was printed into the file at `path`, then deletes it. Nil if nothing
	# was printed or the file is gone.
	def self.collect(path)
		File.open(path, "rb") do |file|
			size = file.size
			tail(file, size) if size > 0
		end
	rescue SystemCallError
		nil
	ensure
		discard(path)
	end

	def self.discard(path)
		File.delete(path)
	rescue SystemCallError
		nil
	end

	def self.tail(file, size)
		if size > LIMIT
			Quickdraw.utf8("[#{size - LIMIT} earlier bytes not shown]\n#{file.pread(LIMIT, size - LIMIT)}")
		else
			Quickdraw.utf8(file.pread(size, 0))
		end
	end

	# Raises SystemCallError if no temporary directory can hold the file.
	def initialize
		@path, @file = create_file
		@file.binmode
		@terminal_stdout = STDOUT.dup
		@terminal_stderr = STDERR.dup
		# Not STDOUT and STDERR, which a test may have closed.
		@stdout = IO.for_fd(1, autoclose: false)
		@stderr = IO.for_fd(2, autoclose: false)
	end

	attr_reader :path

	def start
		flush
		@stdout.reopen(@file)
		@stderr.reopen(@file)
		@capturing = true
	end

	# Back to the terminal, e.g. while loading a file, so what that prints shows.
	def stop
		flush
		@stdout.reopen(@terminal_stdout)
		@stderr.reopen(@terminal_stderr)
		@capturing = false
	end

	def capturing? = @capturing

	# What was printed since the last call, or nil: its end, or all of it if
	# `whole`, for output that would otherwise have been shown as printed. The
	# file is emptied when there's anything to take, so it only ever holds the
	# current test's output.
	def take(whole: false)
		flush
		size = @file.size
		return if size == 0

		output = whole ? Quickdraw.utf8(@file.pread(size, 0)) : self.class.tail(@file, size)
		@file.truncate(0)
		output
	end

	# Shows anything left, e.g. from a test interrupted by Ctrl-C, on the terminal.
	def close
		stop
		rest = take
		@terminal_stdout.write(rest) if rest
		@file.close
		self.class.discard(@path)
	end

	# Appending, so writes land at the end after the file is truncated, even
	# from processes that inherited it.
	private def create_file
		name = "quickdraw-output-#{Process.pid}-#{Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)}"
		directories = [Quickdraw.temporary_directory, "/tmp", "/var/tmp", Dir.pwd].uniq

		directories.each_with_index do |directory, index|
			path = File.join(directory, name)
			return [path, File.new(path, File::RDWR | File::CREAT | File::EXCL | File::APPEND, 0o600)]
		rescue SystemCallError
			raise if index == directories.size - 1
		end
	end

	# A test can replace $stdout with a buffered IO, or close it.
	private def flush
		$stdout.flush unless $stdout.equal?(STDOUT) && STDOUT.sync
		$stderr.flush unless $stderr.equal?(STDERR) && STDERR.sync
	rescue IOError
		nil
	end
end
