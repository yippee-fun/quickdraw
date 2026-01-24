# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.describe "subject" do
	subject { "the subject" }

	it "provides the subject" do
		expect(subject).to eq("the subject")
	end

	it "memoizes the subject" do
		expect(subject).to equal(subject)
	end

	describe "named subject" do
		subject(:my_string) { "named" }

		it "provides subject" do
			expect(subject).to eq("named")
		end

		it "provides named accessor" do
			expect(my_string).to eq("named")
		end

		it "named accessor equals subject" do
			expect(my_string).to equal(subject)
		end
	end

	describe "inheritance" do
		subject { "parent subject" }

		describe "nested" do
			it "inherits subject from parent" do
				expect(subject).to eq("parent subject")
			end
		end

		describe "override" do
			subject { "child subject" }

			it "can override parent subject" do
				expect(subject).to eq("child subject")
			end
		end
	end
end
