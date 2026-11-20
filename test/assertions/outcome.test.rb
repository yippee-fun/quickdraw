# frozen_string_literal: true

class OutcomeTest < Quickdraw::Test
	test "two blocks that return the same thing have the same outcome" do
		assert_equal outcome { %w[a b].join }, outcome { "ab" }
		refute_equal outcome { "a" }, outcome { "b" }
	end

	test "two blocks that raise the same error have the same outcome, whatever objects' addresses" do
		assert_equal outcome { raise ArgumentError, "bad #{Object.new.inspect}" }, outcome { raise ArgumentError, "bad #{Object.new.inspect}" }
		assert_equal outcome { Integer("x") }, raised(ArgumentError, 'invalid value for Integer(): "x"')
		refute_equal outcome { raise ArgumentError, "a" }, outcome { raise TypeError, "a" }
		refute_equal outcome { raise ArgumentError, "opcode 0xdead" }, outcome { raise ArgumentError, "opcode 0xbeef" }
		assert_equal outcome { raise ArgumentError, "bad \xFF".b }, raised(ArgumentError, "bad �")
	end

	test "returning and raising are different outcomes, and a failure shows both" do
		runner = assert_test(failures: 1) { assert_equal outcome { nil }, outcome { raise "nil" } }

		assert_includes Quickdraw.plain_string(runner.failures.first["message"]), "Raised"
		assert_includes Quickdraw.plain_string(runner.failures.first["message"]), "Returned"
	end
end
