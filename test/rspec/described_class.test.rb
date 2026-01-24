# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.describe String do
	it "provides described_class" do
		expect(described_class).to eq(String)
	end

	describe "nested" do
		it "inherits described_class" do
			expect(described_class).to eq(String)
		end
	end

	describe Array do
		it "overrides described_class" do
			expect(described_class).to eq(Array)
		end
	end
end
