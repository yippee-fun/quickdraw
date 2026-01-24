# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.shared_examples "globally defined" do
	it "can be used from anywhere" do
		expect(true).to eq(true)
	end
end

Quickdraw::RSpec.describe "global shared_examples" do
	it_behaves_like "globally defined"

	describe "nested" do
		it_behaves_like "globally defined"
	end
end
