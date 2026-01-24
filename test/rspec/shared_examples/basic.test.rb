# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.describe "shared_examples" do
	shared_examples "a string" do
		it "responds to length" do
			expect(subject).to respond_to(:length)
		end

		it "responds to upcase" do
			expect(subject).to respond_to(:upcase)
		end
	end

	describe "with a simple string" do
		subject { "hello" }

		it_behaves_like "a string"
	end

	describe "with another string" do
		subject { "world" }

		it_behaves_like "a string"
	end

	describe "with customization block" do
		shared_examples "has expected value" do
			it "equals the expected value" do
				expect(subject).to eq(expected)
			end
		end

		describe "first" do
			subject { "foo" }

			it_behaves_like "has expected value" do
				let(:expected) { "foo" }
			end
		end

		describe "second" do
			subject { "bar" }

			it_behaves_like "has expected value" do
				let(:expected) { "bar" }
			end
		end
	end

	describe "scoping" do
		shared_examples "scoped example" do
			it "works" do
				expect(true).to eq(true)
			end
		end

		describe "nested" do
			it_behaves_like "scoped example"
		end
	end
end
