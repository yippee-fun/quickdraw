# frozen_string_literal: true

class DescribeTest < Quickdraw::Test
	def setup
		@order = [:outer]
	end

	def greeting = "hello"

	test "runs at the top level" do
		assert_equal @order, [:outer]
	end

	describe "a group" do
		def setup
			super
			@order << :group
		end

		test "runs the group's setup after its parent's" do
			assert_equal @order, [:outer, :group]
		end

		test "can call its parent's helpers" do
			assert_equal greeting, "hello"
		end

		describe "a nested group" do
			def setup
				super
				@order << :nested
			end

			def greeting = "#{super} again"

			test "runs every setup from the outside in" do
				assert_equal @order, [:outer, :group, :nested]
			end

			test "can override its parent's helpers" do
				assert_equal greeting, "hello again"
			end

			test "has a name that includes each group" do
				assert_match self.class.name, /DescribeTest › a group › a nested group\z/
			end
		end
	end
end
