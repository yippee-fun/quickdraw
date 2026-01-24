# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.describe "describe" do
	describe "with multiple arguments" do
		describe String, "when empty" do
			it "sets described_class from the Class argument" do
				expect(described_class).to eq(String)
			end
		end

		describe Array, "with elements", "and more context" do
			it "sets described_class from the first Class argument" do
				expect(described_class).to eq(Array)
			end
		end

		describe "a feature", "with context" do
			it "works without a class argument" do
				expect(described_class).to be_nil
			end
		end

		describe Hash, Integer do
			it "sets described_class to the first Class/Module" do
				expect(described_class).to eq(Hash)
			end
		end
	end

	describe "context alias" do
		context "when using context" do
			it "behaves like describe" do
				expect(true).to be(true)
			end

			context String, "as context argument" do
				it "sets described_class" do
					expect(described_class).to eq(String)
				end
			end
		end

		context "nested contexts" do
			let(:outer_value) { "outer" }

			context "inner context" do
				let(:inner_value) { "inner" }

				it "inherits from outer context" do
					expect(outer_value).to eq("outer")
					expect(inner_value).to eq("inner")
				end
			end
		end
	end
end
