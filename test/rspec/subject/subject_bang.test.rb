# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.describe "subject!" do
	subject! { @evaluated = true; "eager subject" }

	it "is evaluated before the test runs" do
		expect(@evaluated).to eq(true)
	end

	it "provides the subject" do
		expect(subject).to eq("eager subject")
	end

	describe "named subject!" do
		subject!(:my_eager) { @named_evaluated = true; "named eager" }

		it "is evaluated before the test runs" do
			expect(@named_evaluated).to eq(true)
		end

		it "provides subject" do
			expect(subject).to eq("named eager")
		end

		it "provides named accessor" do
			expect(my_eager).to eq("named eager")
		end
	end
end
