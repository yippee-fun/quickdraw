# frozen_string_literal: true

class EquivalentRubyTest < Quickdraw::Test
	test "#assert_equivalent_ruby pass with identical Ruby" do
		assert_test(passes: 1) do
			assert_equivalent_ruby "def foo; end", "def foo; end"
		end
	end

	test "#assert_equivalent_ruby pass with identical multiline Ruby" do
		assert_test(passes: 1) do
			assert_equivalent_ruby "def foo\n  1 + 2\nend", "def foo\n  1 + 2\nend"
		end
	end

	test "#assert_equivalent_ruby pass with equivalent Ruby (different whitespace)" do
		assert_test(passes: 1) do
			assert_equivalent_ruby "def foo;end", "def foo; end"
		end
	end

	test "#assert_equivalent_ruby pass with equivalent Ruby (different formatting)" do
		assert_test(passes: 1) do
			assert_equivalent_ruby "def foo\n1+2\nend", "def foo\n  1 + 2\nend"
		end
	end

	test "#assert_equivalent_ruby fail with different method names" do
		assert_test(failures: 1) do
			assert_equivalent_ruby "def foo; end", "def bar; end"
		end
	end

	test "#assert_equivalent_ruby fail with different operators" do
		assert_test(failures: 1) do
			assert_equivalent_ruby "1 + 2", "1 - 2"
		end
	end

	test "#assert_equivalent_ruby fail with different values" do
		assert_test(failures: 1) do
			assert_equivalent_ruby "x = 1", "x = 2"
		end
	end

	test "#assert_equivalent_ruby fail with different structure" do
		assert_test(failures: 1) do
			assert_equivalent_ruby "if true; 1; end", "unless true; 1; end"
		end
	end
end
