# frozen_string_literal: true

Quickdraw.configure do |config|
	# config here
end

class Runner
	def initialize
		@failures = []
		@errors = []
		@successes = 0
	end

	attr_reader :failures, :successes, :errors

	def failure!(failure)
		@failures << failure
	end

	def success!(description)
		@successes += 1
	end

	def error!(error)
		@errors << error
	end
end

class Quickdraw::Test
	def assert_test(passes: 0, failures: 0, errors: 0, &block)
		runner = Runner.new

		Quickdraw::Test.new(description: nil, skip: false, block:, runner:).run

		assert_equal runner.successes, passes
		assert_equal runner.failures.size, failures
		assert_equal runner.errors.size, errors

		runner
	end
end

# require 'simplecov'

# SimpleCov.start do
#   enable_coverage :branch
# end
