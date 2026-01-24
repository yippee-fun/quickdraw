# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.describe "aliases" do
	describe "DSL aliases" do
		describe "specify" do
			specify "works as an alias for it" do
				expect(true).to be(true)
			end

			specify { expect(1 + 1).to eq(2) }
		end

		describe "example" do
			example "works as an alias for it" do
				expect(true).to be(true)
			end

			example { expect(1 + 1).to eq(2) }
		end
	end

	describe "expectation aliases" do
		describe "to_not" do
			it "works as an alias for not_to" do
				expect(1).to_not eq(2)
				expect(true).to_not be(false)
				expect([1, 2, 3]).to_not include(4)
			end
		end
	end

	describe "matcher aliases" do
		describe "be_an" do
			it "works as an alias for be_a" do
				expect([]).to be_an(Array)
				expect({}).to be_an(Hash)
			end
		end

		describe "be_falsy" do
			it "works as an alias for be_falsey" do
				expect(false).to be_falsy
				expect(nil).to be_falsy
			end
		end

		describe "be_instance_of" do
			it "works as an alias for be_an_instance_of" do
				expect("hello").to be_instance_of(String)
				expect([1, 2]).to be_instance_of(Array)
			end
		end

		describe "be_kind_of" do
			it "works as an alias for be_a_kind_of" do
				expect("hello").to be_kind_of(Object)
				expect([]).to be_kind_of(Enumerable)
			end
		end

		describe "raise_exception" do
			it "works as an alias for raise_error" do
				expect { raise StandardError, "oops" }.to raise_exception(StandardError)
				expect { raise ArgumentError, "bad arg" }.to raise_exception(ArgumentError)
			end
		end
	end
end
