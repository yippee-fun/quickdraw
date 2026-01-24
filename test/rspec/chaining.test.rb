# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.describe "and chaining" do
	it "passes when both matchers pass" do
		expect(5).to (be > 3).and(be < 10)
	end

	it "works with equality matchers" do
		expect("hello").to be_a(String).and eq("hello")
	end
end

Quickdraw::RSpec.describe "or chaining" do
	it "passes when first matcher passes" do
		expect(5).to eq(5).or(eq(10))
	end

	it "passes when second matcher passes" do
		expect(10).to eq(5).or(eq(10))
	end

	it "passes when both matchers pass" do
		expect(5).to eq(5).or(eq(5))
	end
end
