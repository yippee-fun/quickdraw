# frozen_string_literal: true

require "action_mailer/test_helper"

# Action Mailer's test helpers for a Quickdraw test, with Active Job's (see
# JobHelpers). Delivered emails are cleared before and after each test, even
# if it fails.
module Quickdraw::Rails::MailerHelpers
	include Quickdraw::Rails::JobHelpers

	# Rails' mailer helpers include its job helpers, which come after them here.
	class Bridge < Quickdraw::Rails::JobHelpers::Bridge
		include ActionMailer::TestHelper

		def before_setup
			super
			clear_deliveries
		end

		def after_teardown
			super
			clear_deliveries
		end

		# As Rails does, only for the test delivery method.
		private def clear_deliveries
			ActionMailer::Base.deliveries.clear if ActionMailer::Base.delivery_method == :test
		end
	end

	Quickdraw::Rails::MinitestBridge.forward(
		self,
		:assert_emails, :assert_no_emails, :assert_enqueued_emails, :assert_no_enqueued_emails,
		:assert_enqueued_email_with, :deliver_enqueued_emails, :capture_emails,
	)

	private def rails_helpers = @rails_helpers ||= Bridge.new(self)
end
