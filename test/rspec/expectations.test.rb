# frozen_string_literal: true

require "quickdraw/rspec"

Quickdraw::RSpec.describe "expectations" do
	describe "all" do
		it "passes when all elements match" do
			expect([1, 2, 3]).to all(be < 10)
		end

		it "fails when any element doesn't match" do
			expect([1, 2, 30]).not_to all(be < 10)
		end
	end

	describe "be" do
		it "works with comparisons" do
			expect(5).to be > 3
			expect(5).to be >= 5
			expect(3).to be < 5
			expect(5).to be <= 5
		end

		it "works with equality" do
			expect(true).to be(true)
			expect(false).to be(false)
		end
	end

	describe "be_a / be_an" do
		it "checks if object is an instance of a class or its ancestors" do
			expect("hello").to be_a(String)
			expect("hello").to be_a(Object)
			expect([]).to be_an(Array)
			expect({}).to be_an(Hash)
		end

		it "fails for non-matching types" do
			expect("hello").not_to be_a(Integer)
		end
	end

	describe "be_a_kind_of / be_kind_of" do
		it "checks inheritance chain" do
			expect("hello").to be_a_kind_of(String)
			expect("hello").to be_a_kind_of(Object)
			expect([]).to be_kind_of(Enumerable)
		end
	end

	describe "be_an_instance_of / be_instance_of" do
		it "checks exact class match" do
			expect("hello").to be_an_instance_of(String)
			expect([]).to be_instance_of(Array)
		end

		it "fails for parent classes" do
			expect("hello").not_to be_an_instance_of(Object)
		end
	end

	describe "be_between" do
		it "checks if value is between bounds (inclusive)" do
			expect(5).to be_between(1, 10).inclusive
			expect(1).to be_between(1, 10).inclusive
			expect(10).to be_between(1, 10).inclusive
		end

		it "checks if value is between bounds (exclusive)" do
			expect(5).to be_between(1, 10).exclusive
			expect(1).not_to be_between(1, 10).exclusive
			expect(10).not_to be_between(1, 10).exclusive
		end
	end

	describe "be_falsey / be_falsy" do
		it "matches false and nil" do
			expect(false).to be_falsey
			expect(nil).to be_falsey
			expect(nil).to be_falsy
		end

		it "fails for truthy values" do
			expect(true).not_to be_falsey
			expect(0).not_to be_falsey
			expect("").not_to be_falsey
		end
	end

	describe "be_nil" do
		it "matches nil" do
			expect(nil).to be_nil
		end

		it "fails for non-nil values" do
			expect(false).not_to be_nil
			expect(0).not_to be_nil
		end
	end

	describe "be_truthy" do
		it "matches anything except false and nil" do
			expect(true).to be_truthy
			expect(0).to be_truthy
			expect("").to be_truthy
			expect([]).to be_truthy
		end

		it "fails for false and nil" do
			expect(false).not_to be_truthy
			expect(nil).not_to be_truthy
		end
	end

	describe "be_within" do
		it "checks if value is within delta of expected" do
			expect(5.0).to be_within(0.1).of(5.05)
			expect(5).to be_within(1).of(6)
		end

		it "supports percent_of" do
			expect(100).to be_within(10).percent_of(105)
		end

		it "fails when outside delta" do
			expect(5.0).not_to be_within(0.01).of(5.1)
		end
	end

	describe "change" do
		it "detects changes to a value" do
			array = []
			expect { array << 1 }.to change { array.size }.from(0).to(1)
		end

		it "detects change by amount" do
			counter = [0]
			expect { counter[0] += 5 }.to change { counter[0] }.by(5)
		end

		it "detects no change" do
			value = 1
			expect { value }.not_to change { value }
		end
	end

	describe "contain_exactly" do
		it "matches arrays with same elements in any order" do
			expect([1, 2, 3]).to contain_exactly(3, 2, 1)
			expect([1, 2, 3]).to contain_exactly(1, 2, 3)
		end

		it "fails with different elements" do
			expect([1, 2, 3]).not_to contain_exactly(1, 2)
			expect([1, 2, 3]).not_to contain_exactly(1, 2, 3, 4)
		end
	end

	describe "cover" do
		it "checks if range covers value" do
			expect(1..10).to cover(5)
			expect(1..10).to cover(1, 10)
		end

		it "fails for values outside range" do
			expect(1..10).not_to cover(0)
			expect(1..10).not_to cover(11)
		end
	end

	describe "end_with" do
		it "checks string ending" do
			expect("hello world").to end_with("world")
			expect("hello world").to end_with("o world")
		end

		it "checks array ending" do
			expect([1, 2, 3]).to end_with(3)
			expect([1, 2, 3]).to end_with(2, 3)
		end

		it "fails for non-matching endings" do
			expect("hello").not_to end_with("world")
		end
	end

	describe "eq" do
		it "checks equality using ==" do
			expect(1).to eq(1)
			expect("hello").to eq("hello")
			expect([1, 2]).to eq([1, 2])
		end

		it "fails for non-equal values" do
			expect(1).not_to eq(2)
			expect("hello").not_to eq("world")
		end
	end

	describe "eql" do
		it "checks equality using eql?" do
			expect(1).to eql(1)
			expect("hello").to eql("hello")
		end

		it "distinguishes between 1 and 1.0" do
			expect(1).not_to eql(1.0)
		end
	end

	describe "equal" do
		it "checks object identity" do
			obj = Object.new
			expect(obj).to equal(obj)
		end

		it "fails for equal but not identical objects" do
			expect([1, 2]).not_to equal([1, 2])
		end
	end

	describe "exist" do
		let(:existing_object) do
			Class.new do
				def exist?
					true
				end
			end.new
		end

		let(:non_existing_object) do
			Class.new do
				def exist?
					false
				end
			end.new
		end

		it "checks if object exists" do
			expect(existing_object).to exist
			expect(non_existing_object).not_to exist
		end
	end

	describe "have_attributes" do
		let(:person) do
			Struct.new(:name, :age).new("Alice", 30)
		end

		it "checks object attributes" do
			expect(person).to have_attributes(name: "Alice")
			expect(person).to have_attributes(name: "Alice", age: 30)
		end

		it "fails for non-matching attributes" do
			expect(person).not_to have_attributes(name: "Bob")
		end
	end

	describe "include" do
		it "checks array inclusion" do
			expect([1, 2, 3]).to include(1)
			expect([1, 2, 3]).to include(1, 2)
		end

		it "checks string inclusion" do
			expect("hello world").to include("hello")
			expect("hello world").to include("hello", "world")
		end

		it "checks hash inclusion" do
			expect({ a: 1, b: 2 }).to include(:a)
			expect({ a: 1, b: 2 }).to include(a: 1)
		end

		it "fails for non-included values" do
			expect([1, 2, 3]).not_to include(4)
		end
	end

	describe "match" do
		it "matches strings against regex" do
			expect("hello").to match(/ell/)
			expect("hello").to match(/^h/)
		end

		it "matches hashes partially" do
			expect({ a: 1, b: 2 }).to match(a: 1, b: 2)
		end

		it "fails for non-matching patterns" do
			expect("hello").not_to match(/xyz/)
		end
	end

	describe "match_array" do
		it "matches arrays with same elements regardless of order" do
			expect([1, 2, 3]).to match_array([3, 2, 1])
		end

		it "fails for arrays with different elements" do
			expect([1, 2, 3]).not_to match_array([1, 2])
		end
	end

	describe "output" do
		it "captures stdout" do
			expect { print "hello" }.to output("hello").to_stdout
		end

		it "captures stderr" do
			expect { $stderr.print "error" }.to output("error").to_stderr
		end

		it "matches with regex" do
			expect { puts "hello world" }.to output(/hello/).to_stdout
		end
	end

	describe "raise_error / raise_exception" do
		it "checks for raised errors" do
			expect { raise StandardError, "oops" }.to raise_error(StandardError)
			expect { raise StandardError, "oops" }.to raise_exception(StandardError)
		end

		it "checks error message" do
			expect { raise StandardError, "oops" }.to raise_error(StandardError, "oops")
			expect { raise StandardError, "oops" }.to raise_error(StandardError, /oops/)
		end

		it "checks for specific error class" do
			expect { raise "error" }.to raise_error(RuntimeError)
		end
	end

	describe "respond_to" do
		it "checks if object responds to method" do
			expect("hello").to respond_to(:upcase)
			expect("hello").to respond_to(:upcase, :downcase)
		end

		it "checks arity" do
			expect("hello").to respond_to(:gsub).with(2).arguments
		end

		it "fails for non-existing methods" do
			expect("hello").not_to respond_to(:foo_bar_baz)
		end
	end

	describe "satisfy" do
		it "checks custom condition" do
			expect(5).to satisfy { |n| n > 3 }
			expect(5).to satisfy("be greater than 3") { |n| n > 3 }
		end

		it "fails when condition not met" do
			expect(2).not_to satisfy { |n| n > 3 }
		end
	end

	describe "start_with" do
		it "checks string beginning" do
			expect("hello world").to start_with("hello")
			expect("hello world").to start_with("hello w")
		end

		it "checks array beginning" do
			expect([1, 2, 3]).to start_with(1)
			expect([1, 2, 3]).to start_with(1, 2)
		end

		it "fails for non-matching beginnings" do
			expect("hello").not_to start_with("world")
		end
	end

	describe "throw_symbol" do
		it "checks for thrown symbols" do
			expect { throw :foo }.to throw_symbol(:foo)
		end

		it "checks thrown value" do
			expect { throw :foo, "bar" }.to throw_symbol(:foo, "bar")
		end

		it "fails when symbol not thrown" do
			expect { :noop }.not_to throw_symbol
		end
	end

	describe "yield_control" do
		it "checks if block yields" do
			expect { |b| [1].each(&b) }.to yield_control
		end

		it "checks yield count" do
			expect { |b| [1, 2, 3].each(&b) }.to yield_control.exactly(3).times
			expect { |b| [1, 2].each(&b) }.to yield_control.at_least(1).times
			expect { |b| [1].each(&b) }.to yield_control.at_most(2).times
		end

		it "fails when no yield" do
			expect { |b| [].each(&b) }.not_to yield_control
		end
	end

	describe "yield_successive_args" do
		it "checks successive yield arguments" do
			expect { |b| [1, 2, 3].each(&b) }.to yield_successive_args(1, 2, 3)
		end

		it "fails for wrong arguments" do
			expect { |b| [1, 2].each(&b) }.not_to yield_successive_args(1, 2, 3)
		end
	end

	describe "yield_with_args" do
		it "checks if block yields with specific args" do
			expect { |b| "hello".tap { b.to_proc.call("hello", 42) } }.to yield_with_args("hello", 42)
		end

		it "checks if block yields with any args" do
			expect { |b| [1].each(&b) }.to yield_with_args
		end
	end

	describe "yield_with_no_args" do
		it "checks if block yields without arguments" do
			expect { |b| "hello".tap { b.to_proc.call } }.to yield_with_no_args
		end

		it "fails when yielding with arguments" do
			expect { |b| [1].each(&b) }.not_to yield_with_no_args
		end
	end

	describe "to_not alias" do
		it "works as alias for not_to" do
			expect(1).to_not eq(2)
			expect(true).to_not be(false)
		end
	end
end
