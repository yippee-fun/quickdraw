# frozen_string_literal: true

if defined?(ActionMailer)
	# Named, since mailers are found by name when they deliver later.
	::QuickdrawGreetingMailer = Class.new(ActionMailer::Base) do
		def hello = mail(to: "ada@example.com", from: "quickdraw@example.com", subject: "Hello", body: "Hello")
	end
end

class MailerHelpersTest < Quickdraw::Test
	def setup
		super
		skip "Rails isn’t in the bundle" unless defined?(ActionMailer)
		@test_class = Class.new(Quickdraw::Test) { include Quickdraw::Rails::MailerHelpers }
	end

	test "asserts on emails sent and enqueued" do
		runner = assert_test(passes: 4, failures: 1, test_class: @test_class) do
			assert_emails(1) { QuickdrawGreetingMailer.hello.deliver_now }
			assert_enqueued_emails(1) { QuickdrawGreetingMailer.hello.deliver_later }
			assert_enqueued_email_with(QuickdrawGreetingMailer, :hello)
			assert_equal capture_emails { QuickdrawGreetingMailer.hello.deliver_now }.map(&:subject), ["Hello"]
			assert_emails(2) { QuickdrawGreetingMailer.hello.deliver_now }
		end

		assert_equal runner.failures.first["message"], "2 emails expected, but 1 were sent"
	end

	test "clears delivered emails before and after the test, even if it fails" do
		ActionMailer::Base.deliveries << QuickdrawGreetingMailer.hello.message

		assert_test(passes: 1, failures: 1, test_class: @test_class) do
			assert_no_emails
			QuickdrawGreetingMailer.hello.deliver_now
			assert false
		end

		assert ActionMailer::Base.deliveries.empty?
	end
end
