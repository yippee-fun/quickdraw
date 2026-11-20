# frozen_string_literal: true

Quickdraw.configure do |config|
	# Rails' test helpers, without an app. Only CRuby's bundle has Rails.
	config.group :rails, "test/rails/**/*.test.rb" do
		require "active_job"
		require "action_mailer"
		ActiveJob::Base.logger = Logger.new(nil)
		ActionMailer::Base.delivery_method = :test
	rescue LoadError
		nil
	end
end

class Runner
	def initialize
		@failures = []
		@errors = []
		@successes = 0
	end

	attr_reader :failures, :successes, :errors, :skipped

	def failure!(failure)
		@failures << failure
	end

	def skip!(reason)
		@skipped = { "pending" => false, "reason" => reason }
	end

	def pending!
		@skipped = { "pending" => true, "reason" => nil }
	end

	def success!(description)
		@successes += 1
	end

	def measure(_phase)
		yield
	end

	def error!(error)
		@errors << error
	end
end

class Quickdraw::Test
	def assert_test(passes: 0, failures: 0, errors: 0, test_class: Quickdraw::Test, &block)
		runner = Runner.new

		test_class.new(description: nil, block:, runner:).run

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
