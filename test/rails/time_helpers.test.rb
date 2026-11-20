# frozen_string_literal: true

class TimeHelpersTest < Quickdraw::Test
	def setup
		super
		skip "Rails isn’t in the bundle" unless defined?(ActiveSupport)
		@test_class = Class.new(Quickdraw::Test) { include Quickdraw::Rails::TimeHelpers }
	end

	test "travels in time" do
		assert_test(passes: 3, test_class: @test_class) do
			travel_to(Time.utc(2000)) { assert_equal Time.now.year, 2000 }
			travel_to Time.utc(2001)
			travel 86_400 * 366
			assert_equal Time.now.year, 2002
			freeze_time
			assert_equal Time.now, Time.now
		end
	end

	test "travels back after the test, even if it fails" do
		assert_test(failures: 1, test_class: @test_class) do
			travel_to Time.utc(2000)
			assert false
		end

		assert_operator Time.now.year, :>, 2000
	end
end
