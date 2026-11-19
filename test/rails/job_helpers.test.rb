# frozen_string_literal: true

if defined?(ActiveJob)
	# Named, since jobs are found by name when they're performed.
	::QuickdrawGreetingJob = Class.new(ActiveJob::Base) do
		def self.greeted = @greeted ||= []
		def perform(name) = self.class.greeted << name
	end
end

class JobHelpersTest < Quickdraw::Test
	def setup
		super
		skip "Rails isn’t in the bundle" unless defined?(ActiveJob)
		@test_class = Class.new(Quickdraw::Test) { include Quickdraw::Rails::JobHelpers }
	end

	test "asserts on enqueued jobs" do
		runner = assert_test(passes: 3, failures: 1, test_class: @test_class) do
			QuickdrawGreetingJob.perform_later("Ada")
			assert_enqueued_jobs 1
			assert_enqueued_with(job: QuickdrawGreetingJob, args: ["Ada"])
			assert_enqueued_jobs(1) { QuickdrawGreetingJob.perform_later("Grace") }
			assert_enqueued_with(job: QuickdrawGreetingJob, args: ["Bob"])
		end

		assert_match runner.failures.first["message"], /\ANo enqueued job found with \{job: QuickdrawGreetingJob, args: \["Bob"\]\}/
	end

	test "performs enqueued jobs" do
		assert_test(passes: 1, test_class: @test_class) do
			perform_enqueued_jobs { QuickdrawGreetingJob.perform_later("Ada") }
			assert_performed_jobs 1
		end

		assert_includes QuickdrawGreetingJob.greeted, "Ada"
	end

	test "uses the test's own adapter" do
		test_class = Class.new(@test_class) do
			def queue_adapter_for_test = @queue_adapter_for_test ||= ActiveJob::QueueAdapters::TestAdapter.new
		end

		assert_test(passes: 1, test_class:) do
			assert_same queue_adapter, queue_adapter_for_test
		end
	end

	test "starts with no jobs, and puts the adapter back after the test, even if it fails" do
		assert_test(failures: 1, test_class: @test_class) do
			QuickdrawGreetingJob.perform_later("Ada")
			assert false
		end

		assert ActiveJob::Base._test_adapter.nil?

		assert_test(passes: 1, test_class: @test_class) do
			assert_no_enqueued_jobs
		end
	end
end
