# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.describe "shared_examples with parameters" do
	shared_examples "a measurable object" do |measurement, measurement_methods|
		measurement_methods.each do |measurement_method|
			it "returns #{measurement} from ##{measurement_method}" do
				expect(subject.send(measurement_method)).to eq(measurement)
			end
		end
	end

	describe "Array with 3 items" do
		subject { [1, 2, 3] }
		it_behaves_like "a measurable object", 3, [:size, :length]
	end

	describe "String of 6 characters" do
		subject { "FooBar" }
		it_behaves_like "a measurable object", 6, [:size, :length]
	end

	describe "with single parameter" do
		shared_examples "has size" do |expected_size|
			it "has the expected size" do
				expect(subject.size).to eq(expected_size)
			end
		end

		describe "empty array" do
			subject { [] }
			it_behaves_like "has size", 0
		end

		describe "array with 5 elements" do
			subject { [1, 2, 3, 4, 5] }
			it_behaves_like "has size", 5
		end
	end

	describe "with hash parameter" do
		shared_examples "responds to methods" do |options|
			options[:methods].each do |method_name|
				it "responds to #{method_name}" do
					expect(subject).to respond_to(method_name)
				end
			end

			if options[:negative]
				options[:negative].each do |method_name|
					it "does not respond to #{method_name}" do
						expect(subject).not_to respond_to(method_name)
					end
				end
			end
		end

		describe "String" do
			subject { "hello" }
			it_behaves_like "responds to methods", methods: [:upcase, :downcase], negative: [:keys, :values]
		end

		describe "Hash" do
			subject { { a: 1 } }
			it_behaves_like "responds to methods", methods: [:keys, :values], negative: [:upcase, :downcase]
		end
	end
end
