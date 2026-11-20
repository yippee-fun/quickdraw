# frozen_string_literal: true

class Quickdraw::BasicTest
	# Raised by #skip. An Exception rather than a StandardError, so a test's own
	# `rescue => error` doesn't swallow it.
	class Skip < Exception
		def initialize(reason)
			@reason = reason
			super(reason || "Skipped")
		end

		attr_reader :reason
	end

	# Defines a test. Without a block, the test is pending: listed as still to
	# write, but not a failure. `timeout` is in seconds, overriding
	# Quickdraw::Config.timeout for this test. `mutation: false` exempts it
	# from `quickdraw mutate --unique-kills`, for a test of code that can't be
	# mutated, such as a template or configuration.
	def self.test(description = nil, timeout: nil, mutation: true, &block)
		line = block ? block.source_location[1] : caller_locations(1, 1).first.lineno

		if block
			@occurrences ||= {}
			@description_counts ||= Hash.new(0)
			@occurrences[block.source_location] = @description_counts[description] += 1
		end

		Quickdraw.register(Quickdraw::Definition.new(test_class: self, description:, block:, timeout:, line:, mutation:))
	end

	# Which of the class's tests with its description the test with `block` is,
	# from 1. A test made other than by `test` is the first.
	def self.occurrence(block) = @occurrences&.[](block.source_location) || 1

	# Groups tests under a description, which prefixes their names. The group is
	# a subclass, so it can define helpers and override setup, calling super.
	def self.describe(description, &block)
		parent_name = name || "(anonymous)"

		Class.new(self) do
			set_temporary_name("#{parent_name} › #{description}")
			class_exec(&block)
		end
	end

	def initialize(description:, block:, runner:)
		@description = description
		@block = block
		@runner = runner
		@deferred = nil
	end

	# Stops the test and reports it as skipped, with an optional reason.
	# Assertions it already made still count.
	def skip(reason = nil)
		raise Skip.new(reason)
	end

	# Runs the block once the test and its teardown have finished, even if they
	# failed. Deferred blocks run in reverse order, so cleanup unwinds setup.
	def defer(&block)
		(@deferred ||= []) << block

		nil
	end

	def match
		yield
		success!
	rescue NoMatchingPatternError => e
		failure! { e.message }
	end

	def assert(value)
		if value
			success!
		elsif block_given?
			failure! { yield(value) }
		else
			failure! { "expected #{value.inspect} to be truthy" }
		end

		nil
	end

	def refute(value)
		if !value
			success!
		elsif block_given?
			failure! { yield(value) }
		else
			failure! { "expected #{value.inspect} to be falsy" }
		end

		nil
	end

	# Indicate that an assertion passed successfully.
	def success!
		runner.success!(@description)

		nil
	end

	# Indicate that an assertion failed.
	def failure!
		test_path = @block.source_location[0]
		locations = caller_locations

		location = locations.find { |it| it.path == test_path } ||
			locations.find { |it| !it.path.start_with?(Quickdraw::LIB) } ||
			locations.first

		runner.failure!({
			"message" => Quickdraw.plain_string(yield),
			"path" => location.path,
			"line" => location.lineno,
		})

		nil
	end

	def error!(error)
		runner.error!(Quickdraw.serialize_error(error))

		nil
	end

	# What records assertions: a property's case while one of this test's runs
	# (see Test#check), in its fiber and the threads it starts, or the test's.
	private def runner
		test, recorder = Fiber[:quickdraw_case]
		test.equal?(self) ? recorder : @runner
	end

	def setup = nil
	def teardown = nil
	def around_test = yield

	# Inside config's around_test callbacks (see Configuration#around_test), so
	# they cover setup and teardown too, and see the test's exceptions.
	def run
		Quickdraw::Config.around(self) { run_test }
	rescue Skip => skip
		@runner.skip!(skip.reason)
	rescue Quickdraw::Interrupted
		raise
	rescue Exception => error
		error!(error)
	end

	private def run_block = instance_exec(&@block)

	private def run_test
		@runner.measure("setup") { setup }
		around_test { @runner.measure("test") { run_block } }
	ensure
		# Cleanup carries on after Ctrl-C, which then stops the worker.
		interrupted = nil
		cleanups = [-> { @runner.measure("teardown") { teardown } }]

		# Deferred blocks are taken, so an around_test that runs the test again
		# doesn't repeat them, including those teardown and cleanup defer.
		until cleanups.empty?
			cleanups.each do |cleanup|
				cleanup.call
			rescue Exception => error
				case error
				in Quickdraw::Interrupted then interrupted = error
				else error!(error)
				end
			end

			cleanups = @deferred&.reverse || []
			@deferred = nil
		end

		raise interrupted if interrupted
	end
end
