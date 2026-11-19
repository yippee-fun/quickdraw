# frozen_string_literal: true

require "active_job/test_helper"

# Active Job's test helpers for a Quickdraw test: jobs go to the test adapter,
# as in Rails' tests, and are cleared before each test. The adapter is put back
# after the test, even if it fails. Needs `setup` to call super.
module Quickdraw::Rails::JobHelpers
	class Bridge < Quickdraw::Rails::MinitestBridge
		include ActiveJob::TestHelper
		include Quickdraw::Rails::MinitestBridge::Assertions

		def queue_adapter_for_test = @test.queue_adapter_for_test
	end

	Quickdraw::Rails::MinitestBridge.forward(
		self,
		:assert_enqueued_jobs, :assert_no_enqueued_jobs, :assert_enqueued_with,
		:assert_performed_jobs, :assert_no_performed_jobs, :assert_performed_with,
		:perform_enqueued_jobs, :enqueued_jobs, :performed_jobs, :queue_adapter,
	)

	# An adapter for the test's jobs, such as ActiveJob::QueueAdapters::TestAdapter.new,
	# rather than the one the app sets, if any.
	def queue_adapter_for_test = nil

	def setup
		helpers = rails_helpers
		helpers.before_setup
		defer { helpers.after_teardown }
		super
	end

	private def rails_helpers = @rails_helpers ||= Bridge.new(self)
end
