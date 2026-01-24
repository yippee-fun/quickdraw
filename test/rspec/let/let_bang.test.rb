# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.describe "let!" do
	let!(:eager_value) { @evaluated = true; "eager" }

	it "is evaluated before the test runs" do
		expect(@evaluated).to eq(true)
	end

	it "provides the value" do
		expect(eager_value).to eq("eager")
	end

	it "memoizes the value" do
		expect(eager_value).to equal(eager_value)
	end

	describe "inheritance" do
		let!(:parent_eager) { @parent_evaluated = true; "parent" }

		describe "nested" do
			it "inherits let! from parent and evaluates it" do
				expect(@parent_evaluated).to eq(true)
				expect(parent_eager).to eq("parent")
			end
		end
	end
end
