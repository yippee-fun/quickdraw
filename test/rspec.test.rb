# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.describe "RSpec" do
	describe String do
		describe "test" do
			let(:example) { "Hello" }
			subject { "Hello" }

			it "works" do
				expect(example).to eq(subject)
			end
		end
	end
end
