# frozen_string_literal: true

require "active_support/testing/time_helpers"

# Active Support's time helpers (travel_to, travel, freeze_time, travel_back)
# for a Quickdraw test. Time travels back after the test, even if it fails.
module Quickdraw::Rails::TimeHelpers
	include ActiveSupport::Testing::TimeHelpers

	# The other helpers travel through this one.
	def travel_to(...)
		unless @travelling
			@travelling = true

			defer do
				@travelling = false
				travel_back
			end
		end

		super
	end
end
