# frozen_string_literal: true

# Subclasses, since TruffleRuby doesn't name a class assigned to a constant in
# the anonymous module test files load in.
class Point < Data.define(:x, :y); end
class Pair < Struct.new(:left, :right); end
class Shadowing < Data.define(:to_h, :each_pair); end

class Account
	def initialize(owner, balance)
		@owner = owner
		@balance = balance
	end
end

class Money
	def initialize(cents) = @cents = cents
	def inspect = "$#{@cents / 100.0}"
end

class InspectorTest < Quickdraw::Test
	def pretty(value) = Quickdraw::Inspector.pretty(value)

	test "puts each element of a hash or array on its own line, nested" do
		assert_equal pretty({ name: "Ada", tags: [:admin], ids: { "github" => 1 } }), <<~TEXT.chomp
			{
			  name: "Ada",
			  tags: [
			    :admin,
			  ],
			  ids: {
			    "github" => 1,
			  },
			}
		TEXT
	end

	test "writes symbol keys that need quotes as Ruby does" do
		assert_equal pretty({ "my key": 1 }), %({\n  "my key": 1,\n})
	end

	test "expands Data, Structs and Sets" do
		assert_equal pretty(Point.new(x: 1, y: 2)), "#<data Point\n  x: 1,\n  y: 2,\n>"
		assert_equal pretty(Pair.new(1, 2)), "#<struct Pair\n  left: 1,\n  right: 2,\n>"
		assert_equal pretty(Set[1]), "#<Set {\n  1,\n}>"
	end

	test "expands plain objects without their address" do
		assert_equal pretty(Account.new("Ada", 10)), "#<Account\n  @owner: \"Ada\",\n  @balance: 10,\n>"
	end

	test "uses a custom inspect as it is" do
		assert_equal pretty(Money.new(150)), "$1.5"
	end

	test "leaves empty collections and scalars on one line" do
		assert_equal pretty([]), "[]"
		assert_equal pretty({}), "{}"
		assert_equal pretty(1.5), "1.5"
		assert_equal pretty(nil), "nil"
	end

	test "expands collections of falsy values" do
		assert_equal pretty([nil, false]), "[\n  nil,\n  false,\n]"
	end

	test "expands records whose members shadow their own methods" do
		assert_equal pretty(Shadowing.new(to_h: "a", each_pair: "b")), %(#<data Shadowing\n  to_h: "a",\n  each_pair: "b",\n>)
	end

	test "doesn't loop on cycles" do
		cycle = [1]
		cycle << cycle

		assert_equal pretty(cycle), "[\n  1,\n  Array(…),\n]"
	end

	test "assert_equal diffs structures element by element" do
		runner = assert_test(failures: 1) do
			assert_equal({ a: 1, b: [1, 2] }, { a: 1, b: [1, 3] })
		end

		message = runner.failures.last["message"].gsub(/\e\[[\d;]*m/, "")
		assert_includes message, "-     3,\n+     2,"
		refute_includes message, "a: 1,\n-"
	end
end
