# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.describe "alias_it_should_behave_like_to" do
	shared_examples "sortability" do
		it "responds to <=>" do
			expect(sortable).to respond_to(:<=>)
		end
	end

	shared_examples "comparable" do
		it "responds to <" do
			expect(comparable).to respond_to(:<)
		end

		it "responds to >" do
			expect(comparable).to respond_to(:>)
		end
	end

	describe "with custom description prefix" do
		alias_it_should_behave_like_to :it_has_behavior, "has behavior:"

		describe String do
			it_has_behavior "sortability" do
				let(:sortable) { "sample string" }
			end
		end

		describe Integer do
			it_has_behavior "sortability" do
				let(:sortable) { 42 }
			end
		end
	end

	describe "without custom description prefix" do
		alias_it_should_behave_like_to :it_works_like

		describe Array do
			it_works_like "sortability" do
				let(:sortable) { [1, 2, 3] }
			end
		end
	end

	describe "with parameters" do
		shared_examples "has size" do |expected_size|
			it "has size #{expected_size}" do
				expect(subject.size).to eq(expected_size)
			end
		end

		alias_it_should_behave_like_to :it_has_size, "has size:"

		describe "array" do
			subject { [1, 2, 3] }
			it_has_size "has size", 3
		end

		describe "string" do
			subject { "hello" }
			it_has_size "has size", 5
		end
	end

	describe "with customization block" do
		alias_it_should_behave_like_to :it_exhibits, "exhibits:"

		describe Float do
			it_exhibits "comparable" do
				let(:comparable) { 3.14 }
			end
		end
	end

	describe "multiple aliases" do
		alias_it_should_behave_like_to :behaves_as, "behaves as:"
		alias_it_should_behave_like_to :acts_like, "acts like:"

		describe "using behaves_as" do
			behaves_as "sortability" do
				let(:sortable) { "test" }
			end
		end

		describe "using acts_like" do
			acts_like "sortability" do
				let(:sortable) { 123 }
			end
		end
	end

	describe "alias inherits nested context behavior" do
		alias_it_should_behave_like_to :it_demonstrates, "demonstrates:"

		shared_examples "defines value" do
			let(:value) { "from shared" }

			it "has the shared value" do
				expect(value).to eq("from shared")
			end
		end

		it_demonstrates "defines value"

		# Since aliases create nested contexts like it_behaves_like,
		# we can define our own let without conflict
		let(:value) { "outer" }

		it "has its own value in outer context" do
			expect(value).to eq("outer")
		end
	end
end
