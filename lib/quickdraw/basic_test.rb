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
		Quickdraw.register(definition(description, line:, timeout:, mutation:, after_tests: false, &block))
	end

	# Defines a test that runs once the class's other tests in its file, its
	# describe groups' included, have passed, in whichever workers they ran.
	# The block is given what they gathered (see #gather), in the order they're
	# defined, to check something of them all, such as that between them they
	# render every branch of a template.
	#
	# It's skipped if one of them doesn't pass. Selecting it selects them, and
	# it isn't selected without them.
	def self.after_tests(description = nil, timeout: nil, &block)
		raise ::ArgumentError, "after_tests needs a block." unless block

		Quickdraw.register(definition(description, line: Quickdraw.defining_line(block), timeout:, mutation: false, after_tests: true, &block))
	end

	# Registered by the method defining the test, whose caller Quickdraw.register
	# looks at.
	private_class_method def self.definition(description, line:, timeout:, mutation:, after_tests:, &block)
		if block
			@occurrences ||= {}
			@description_counts ||= Hash.new(0)
			@occurrences[block.source_location] = @description_counts[description] += 1
		end

		Quickdraw::Definition.new(test_class: self, description:, block:, timeout:, line:, mutation:, after_tests:)
	end

	# Which of the class's tests with its description the test with `block` is,
	# from 1. A test made other than by `test` is the first.
	def self.occurrence(block) = @occurrences&.[](block.source_location) || 1

	# Groups tests under a description, which prefixes their names. The group is
	# a subclass, so it can define helpers and override setup, calling super.
	def self.describe(description, &block)
		parent = self
		parent_name = name || "(anonymous)"

		Class.new(self) do
			set_temporary_name("#{parent_name} › #{description}")
			@described_in = parent
			class_exec(&block)
		end
	end

	# Whether it's `test_class`, or a group describe made in it.
	def self.within?(test_class) = equal?(test_class) || !!@described_in&.within?(test_class)

	# `gathered` is what an after_tests test is given.
	def initialize(description:, block:, runner:, gathered: nil)
		@description = description
		@block = block
		@runner = runner
		@gathered = gathered
		@deferred = nil
		@contexts = nil
		@raised_context = nil
	end

	# Gives a copy of `value`, which must be plain data (see Quickdraw.plain_copy),
	# to the class's after_tests tests.
	def gather(value)
		@runner.gather(Quickdraw.plain_copy(value))

		nil
	end

	# Shows what the block returns with each failure or error later in the
	# test, such as a command's output: `context { result.output }`. The block
	# is only called when there's one to show it with.
	def context(&block)
		raise ::ArgumentError, "context needs a block." unless block

		(@contexts ||= []) << block

		nil
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

		failure = {
			"message" => Quickdraw.plain_string(yield),
			"path" => location.path,
			"line" => location.lineno,
		}
		failure["context"] = context_text if context?

		runner.failure!(failure)

		nil
	end

	def error!(error)
		problem = Quickdraw.serialize_error(error)

		if context?
			# As it was when the test raised the error, if it did, since cleanup
			# may remove what the context shows.
			raised, text = @raised_context
			problem["context"] = raised.equal?(error) ? text : context_text
		end

		runner.error!(problem)

		nil
	end

	# Whether there's context to show with a problem: not for one inside a
	# context block, in this fiber, which would show them again.
	private def context? = @contexts && !Thread.current[:quickdraw_showing_context]

	private def context_text
		Thread.current[:quickdraw_showing_context] = true
		@contexts.dup.map { |block| Quickdraw.utf8(Quickdraw.plain_string(context_of(block))) }.join("\n")
	ensure
		Thread.current[:quickdraw_showing_context] = nil
	end

	# A context block's text, or what it raised, even a skip, which would
	# otherwise hide the failure it's shown with.
	private def context_of(block)
		case block.call
		in String => text then text
		in value then Quickdraw::Inspector.pretty(value)
		end
	rescue Quickdraw::Interrupted
		raise
	rescue Exception => error
		"context { … } raised #{error.class}: #{error.message}"
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

	private def run_block = @gathered ? instance_exec(@gathered, &@block) : instance_exec(&@block)

	private def run_test
		@runner.measure("setup") { setup }
		around_test { @runner.measure("test") { run_block } }
	rescue Skip, Quickdraw::Interrupted
		raise
	rescue Exception => error
		@raised_context = [error, context_text] if context?
		raise
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
