# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.describe "let" do
	let(:value) { "hello" }

	it "provides the value" do
		expect(value).to eq("hello")
	end

	it "memoizes the value" do
		expect(value).to equal(value)
	end

	describe "with a counter" do
		let(:counter) { @count ||= 0; @count += 1 }

		it "is lazy - not evaluated until called" do
			# counter not called yet, so @count should be nil
			expect(@count).to be_nil
			expect(counter).to eq(1)
		end

		it "memoizes across multiple calls in same test" do
			expect(counter).to eq(1)
			expect(counter).to eq(1)
			expect(counter).to eq(1)
		end
	end

	describe "inheritance" do
		let(:inherited) { "parent" }

		describe "nested" do
			it "inherits let from parent" do
				expect(inherited).to eq("parent")
			end
		end

		describe "override" do
			let(:inherited) { "child" }

			it "can override parent let" do
				expect(inherited).to eq("child")
			end
		end
	end

	describe "referencing other lets" do
		let(:first) { "hello" }
		let(:second) { "#{first} world" }

		it "can reference other let values" do
			expect(second).to eq("hello world")
		end
	end
end
