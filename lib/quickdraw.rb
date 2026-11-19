# frozen_string_literal: true

module Quickdraw
	module NoBox
		def self.require(...)
			Kernel.require(...)
		end

		def self.const_missing(name)
			Kernel.const_get(name).tap { |it| const_set(name, it) }
		end
	end

	Box = (defined?(Ruby::Box) && ENV["RUBY_BOX"]) ? Ruby::Box.new : NoBox

	LIB = __dir__

	autoload :CLI, "quickdraw/cli"
	autoload :Commands, "quickdraw/commands"
	autoload :Watch, "quickdraw/watch"
	autoload :Replay, "quickdraw/replay"
	autoload :Sampler, "quickdraw/sampler"
	autoload :Profile, "quickdraw/profile"
	autoload :Diff, "quickdraw/diff"
	autoload :Inspector, "quickdraw/inspector"
	autoload :Test, "quickdraw/test"
	autoload :Timer, "quickdraw/timer"
	autoload :Loader, "quickdraw/loader"
	autoload :Worker, "quickdraw/worker"
	autoload :Watchdog, "quickdraw/watchdog"
	autoload :Channel, "quickdraw/channel"
	autoload :Platform, "quickdraw/platform"
	autoload :Reporters, "quickdraw/reporters"
	autoload :Outcome, "quickdraw/outcome"
	autoload :Timings, "quickdraw/timings"
	autoload :History, "quickdraw/history"
	autoload :Filter, "quickdraw/filter"
	autoload :WorkerTuner, "quickdraw/worker_tuner"
	autoload :Assertions, "quickdraw/assertions"
	autoload :Coordinator, "quickdraw/coordinator"
	autoload :ArgumentError, "quickdraw/errors/argument_error"
	autoload :Configuration, "quickdraw/configuration"
	autoload :HTMLPrettifier, "quickdraw/html_prettifier"
	autoload :BasicTest, "quickdraw/basic_test"

	# Each test's stats are sent as one array of integers: wall time for each of
	# PHASES, then CPU time, GC time and allocations for the whole test. Times are
	# in nanoseconds; the coordinator converts them to seconds when they arrive.
	# Marshal writes floats as decimal text, so sending float seconds made every
	# result four times slower to send.
	PHASES = ["setup", "test", "teardown"].freeze
	STATS = [*PHASES, "cpu", "gc", "allocations"].freeze

	# A test as a file defines it. `block` is nil for a pending test, which is
	# why the line is kept separately.
	Definition = Data.define(:test_class, :description, :block, :timeout, :line)

	# Raised in a worker on Ctrl-C. Not an Interrupt or StandardError, so tests
	# can't rescue it by accident; their teardown and deferred blocks still run.
	class Interrupted < Exception; end

	Null = Object.new.freeze
	Error = Module.new
	Config = Configuration.new

	def self.configure(&)
		yield Config
		Config.freeze
	end

	# Collects the tests defined while loading the test file at `path`.
	# `test_files` is a Hash keyed by the paths of every selected test file.
	def self.collect_tests(path, test_files)
		@loading = path
		@test_files = test_files
		@tests = []
		yield
		@tests
	ensure
		@loading = @test_files = @tests = nil
	end

	def self.register(test)
		raise "Tests can only be defined while Quickdraw loads a test file." unless @tests

		# Tests defined by another selected test file that this one requires
		# belong to that file. Quickdraw loads it separately.
		file = caller_locations.find { |location| location.label == "<top (required)>" }&.path

		return if file && file != @loading && @test_files.key?(file)

		@tests << test
	end

	# Deletes a file, or a directory and everything in it, without following
	# symlinks. Core Ruby only, since it runs alongside user code (fileutils
	# would leak into tests).
	def self.remove_tree(path)
		# A trailing slash would make File.symlink? see the link's target.
		path = path.sub(%r{(?<=.)/+\z}, "")

		if File.directory?(path) && !File.symlink?(path)
			# A read-only directory's entries can't be deleted until it's writable.
			File.chmod(File.stat(path).mode | 0o700, path)
			Dir.each_child(path) { |child| remove_tree(File.join(path, child)) }
			Dir.rmdir(path)
		else
			File.delete(path)
		end
	rescue Errno::ENOENT
		nil
	end

	# 64-bit FNV-1a. Unlike String#hash, it's the same in every process and run.
	def self.stable_hash(string)
		string.each_byte.reduce(0xcbf29ce484222325) do |hash, byte|
			((hash ^ byte) * 0x100000001b3) & 0xffffffffffffffff
		end
	end

	# The string as valid UTF-8, with anything invalid or unmappable replaced.
	# Binary strings, such as ARGV without a UTF-8 locale, are taken to be UTF-8.
	def self.utf8(string)
		case string.encoding
		in Encoding::UTF_8
			string.scrub
		in Encoding::BINARY | Encoding::US_ASCII
			String.new(string, encoding: Encoding::UTF_8).scrub
		else
			string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
		end
	end

	# A copy without subclass or instance variables, which may not survive Marshal.
	def self.plain_string(value)
		String.new(value.to_s)
	end

	def self.serialize_error(error)
		{
			"name" => plain_string(error.class.name),
			"message" => plain_string(error.message),
			"backtrace" => (error.backtrace || []).map { |frame| plain_string(frame) },
		}
	end

	# Runs the block in a forked process and returns its Marshal-able result, so
	# anything it requires stays out of the processes that run tests. If the child
	# exits without a result (e.g. after printing --help), the parent exits with
	# the child's status.
	def self.isolate
		return yield unless Process.respond_to?(:fork)

		reader, writer = IO.pipe

		pid = Process.fork do
			reader.close
			writer.write(Marshal.dump(yield))
			$stdout.flush
			$stderr.flush
			exit!(0)
		end

		writer.close
		data = reader.read
		reader.close
		_, status = Process.wait2(pid)

		exit(status.exitstatus || 1) if data.empty?

		Marshal.load(data)
	end
end
