# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.describe "it_should_behave_like" do
	shared_examples "a measurable object" do |measurement, measurement_methods|
		measurement_methods.each do |measurement_method|
			it "returns #{measurement} from ##{measurement_method}" do
				expect(subject.send(measurement_method)).to eq(measurement)
			end
		end
	end

	describe "Array with 3 items" do
		subject { [1, 2, 3] }
		it_should_behave_like "a measurable object", 3, [:size, :length]
	end

	describe "String of 6 characters" do
		subject { "FooBar" }
		it_should_behave_like "a measurable object", 6, [:size, :length]
	end

	describe "basic usage" do
		shared_examples "a string-like object" do
			it "responds to length" do
				expect(subject).to respond_to(:length)
			end

			it "responds to upcase" do
				expect(subject).to respond_to(:upcase)
			end
		end

		describe "with a string" do
			subject { "hello" }
			it_should_behave_like "a string-like object"
		end
	end

	describe "with customization block" do
		shared_examples "has expected value" do
			it "equals the expected value" do
				expect(subject).to eq(expected)
			end
		end

		describe "first" do
			subject { "foo" }

			it_should_behave_like "has expected value" do
				let(:expected) { "foo" }
			end
		end

		describe "second" do
			subject { "bar" }

			it_should_behave_like "has expected value" do
				let(:expected) { "bar" }
			end
		end
	end

	describe "creates nested context like it_behaves_like" do
		shared_examples "defines a method" do
			let(:value) { "shared" }

			it "has the value" do
				expect(value).to eq("shared")
			end
		end

		it_should_behave_like "defines a method"

		# Since it_should_behave_like creates a nested context,
		# we can define our own let without conflict
		let(:value) { "outer" }

		it "has its own value in outer context" do
			expect(value).to eq("outer")
		end
	end
end
