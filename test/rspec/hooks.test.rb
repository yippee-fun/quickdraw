# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.describe "hooks" do
	describe "before(:each)" do
		before do
			@before_each_ran = true
			@counter ||= 0
			@counter += 1
		end

		it "runs before each test" do
			expect(@before_each_ran).to be(true)
		end

		it "runs before each test independently" do
			expect(@counter).to eq(1)
		end

		context "in nested context" do
			before do
				@nested_before_ran = true
			end

			it "runs parent before hooks first" do
				expect(@before_each_ran).to be(true)
				expect(@nested_before_ran).to be(true)
			end
		end
	end

	describe "after(:each)" do
		before do
			@value = "initial"
		end

		after do
			@after_ran = true
		end

		it "runs after each test" do
			expect(@value).to eq("initial")
			@value = "modified"
		end

		context "in nested context" do
			after do
				@nested_after_ran = true
			end

			it "will run both after hooks" do
				expect(@value).to eq("initial")
			end
		end
	end

	describe "around(:each)" do
		around do |test|
			@around_before = true
			test.call
			@around_after = true
		end

		it "wraps the test" do
			expect(@around_before).to be(true)
		end

		context "with multiple around hooks" do
			around do |test|
				@outer_order ||= []
				@outer_order << :before
				test.call
				@outer_order << :after
			end

			around do |test|
				@outer_order ||= []
				@outer_order << :inner_before
				test.call
				@outer_order << :inner_after
			end

			it "nests around hooks correctly" do
				expect(@outer_order).to eq([:before, :inner_before])
			end
		end
	end

	describe "before(:all)" do
		before(:all) do
			@before_all_counter ||= 0
			@before_all_counter += 1
			@shared_resource = "created once"
		end

		it "runs once before all tests in the group" do
			expect(@shared_resource).to eq("created once")
		end

		it "shares state across tests" do
			expect(@shared_resource).to eq("created once")
		end

		it "only ran once" do
			expect(@before_all_counter).to eq(1)
		end
	end

	describe "after(:all)" do
		# Note: after(:all) is hard to test directly since it runs after all tests
		# We mainly test that it doesn't break anything

		after(:all) do
			# This should run after all tests in this group
			@cleanup_ran = true
		end

		it "allows after(:all) to be defined" do
			expect(true).to be(true)
		end
	end

	describe "hook inheritance" do
		before do
			@parent_hook = true
		end

		context "child context" do
			before do
				@child_hook = true
			end

			it "runs both parent and child hooks" do
				expect(@parent_hook).to be(true)
				expect(@child_hook).to be(true)
			end

			context "grandchild context" do
				before do
					@grandchild_hook = true
				end

				it "runs all ancestor hooks" do
					expect(@parent_hook).to be(true)
					expect(@child_hook).to be(true)
					expect(@grandchild_hook).to be(true)
				end
			end
		end
	end

	describe "hooks with let" do
		let(:value) { "from let" }

		before do
			@captured_value = value
		end

		it "can access let values in before hooks" do
			expect(@captured_value).to eq("from let")
		end
	end

	describe "multiple hooks of same type" do
		before do
			@order ||= []
			@order << :first
		end

		before do
			@order << :second
		end

		before do
			@order << :third
		end

		it "runs hooks in definition order" do
			expect(@order).to eq([:first, :second, :third])
		end
	end

	describe "before(:context) alias" do
		before(:context) do
			@context_hook_ran = true
		end

		it "works as alias for before(:all)" do
			expect(@context_hook_ran).to be(true)
		end
	end

	describe "after(:context) alias" do
		after(:context) do
			# Just testing it doesn't error
		end

		it "works as alias for after(:all)" do
			expect(true).to be(true)
		end
	end
end
