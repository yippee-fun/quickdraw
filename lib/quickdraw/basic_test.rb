# frozen_string_literal: true

class Quickdraw::BasicTest
	def self.test(description = nil, &block)
		Quickdraw.register([self, description, block])
	end

	def initialize(description:, block:, runner:)
		@description = description
		@block = block
		@runner = runner
	end

	def run
		setup
		around_test { instance_exec(&@block) }
	rescue Exception => error
		error!(error)
	ensure
		begin
			teardown
		rescue Exception => error
			error!(error)
		end
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

	def refute(value, ...)
		assert(!value, ...)
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
end
