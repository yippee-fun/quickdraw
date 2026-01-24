# frozen_string_literal: true

class Quickdraw::BasicTest
	def self.test(description = nil, skip: false, &block)
		$quickdraw_runner << [self, description, skip, block]
	end

	def initialize(description:, skip:, block:, runner:)
		@description = description
		@skip = skip
		@block = block
		@runner = runner
	end

	def run
		setup
		around_test { instance_exec(&@block) }
		teardown
	rescue Exception => error
		error!({
			"location" => @block.source_location,
			"description" => @description,
			"message" => error.message,
			"name" => error.class.name,
			# "detailed_message" => error.detailed_message,
			"backtrace" => error.backtrace,
		})
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
		if @skip
			@runner.failure!("The skipped test `#{@description}` started passing.")
		else
			@runner.success!(@description)
		end

		nil
	end

	# Indicate that an assertion failed.
	def failure!(&)
		if @skip
			@runner.success!(@description)
		else
			test_location = @block.source_location
			locations = caller_locations
			location = locations.find { |it| it.path.end_with?(".test.rb") } || locations.first

			@runner.failure!({
				"class_name" => self.class.name,
				"test_path" => test_location[0],
				"test_line" => test_location[1],
				"description" => @description,
				"message" => yield,
				"path" => location.path,
				"line" => location.lineno,
			})
		end

		nil
	end

	def error!(...)
		if @skip
			@runner.success!(@description)
		else
			@runner.error!(...)
		end

		nil
	end

	def setup = nil
	def teardown = nil
	def around_test = yield
end
