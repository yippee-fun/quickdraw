# frozen_string_literal: true

class Quickdraw::BasicTest
	# `timeout` is in seconds, overriding Quickdraw::Config.timeout for this test.
	def self.test(description = nil, timeout: nil, &block)
		Quickdraw.register([self, description, block, timeout])
	end

	def initialize(description:, block:, runner:)
		@description = description
		@block = block
		@runner = runner
		@deferred = nil
	end

	def run
		@runner.measure("setup") { setup }
		around_test { @runner.measure("test") { instance_exec(&@block) } }
	rescue Exception => error
		error!(error)
	ensure
		begin
			@runner.measure("teardown") { teardown }
		rescue Exception => error
			error!(error)
		end

		run_deferred
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
		@runner.success!(@description)

		nil
	end

	# Indicate that an assertion failed.
	def failure!
		test_path = @block.source_location[0]
		locations = caller_locations

		location = locations.find { |it| it.path == test_path } ||
			locations.find { |it| !it.path.start_with?(Quickdraw::LIB) } ||
			locations.first

		@runner.failure!({
			"message" => Quickdraw.plain_string(yield),
			"path" => location.path,
			"line" => location.lineno,
		})

		nil
	end

	def error!(error)
		@runner.error!(Quickdraw.serialize_error(error))

		nil
	end

	def setup = nil
	def teardown = nil
	def around_test = yield

	private def run_deferred
		@deferred&.reverse_each do |block|
			block.call
		rescue Exception => error
			error!(error)
		end
	end
end
