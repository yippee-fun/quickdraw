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
	autoload :Diff, "quickdraw/diff"
	autoload :Test, "quickdraw/test"
	autoload :Timer, "quickdraw/timer"
	autoload :Loader, "quickdraw/loader"
	autoload :Worker, "quickdraw/worker"
	autoload :Channel, "quickdraw/channel"
	autoload :Platform, "quickdraw/platform"
	autoload :Reporter, "quickdraw/reporter"
	autoload :Assertions, "quickdraw/assertions"
	autoload :Coordinator, "quickdraw/coordinator"
	autoload :ArgumentError, "quickdraw/errors/argument_error"
	autoload :Configuration, "quickdraw/configuration"
	autoload :HTMLPrettifier, "quickdraw/html_prettifier"
	autoload :BasicTest, "quickdraw/basic_test"

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
