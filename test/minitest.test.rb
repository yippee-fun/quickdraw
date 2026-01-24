# frozen_string_literal: true

require "quickdraw/minitest"

class MinitestTest < Quickdraw::Minitest::Test
	def test_assert_equal
		assert_equal(1, 1)
	end

	def test_assert_empty
		assert_empty([])
	end

	def test_assert_in_delta
		assert_in_delta(1.0, 1.0, 0.1)
	end

	def test_assert_in_epsilon
		assert_in_epsilon(1.0, 1.0, 0.1)
	end

	def test_assert_includes
		assert_includes([1, 2, 3], 3)
	end

	def test_assert_instance_of
		assert_instance_of(String, "Hello")
	end

	def test_assert_kind_of
		assert_kind_of(String, "Hello")
	end

	def test_assert_match
		assert_match(/Hello/, "Hello")
	end

	def test_assert_nil
		assert_nil(nil)
	end

	def test_assert_operator
		assert_operator(1, :<, 2)
	end

	def test_assert_path_exists
		assert_path_exists("test/minitest.test.rb")
	end

	def test_assert_pattern
		assert_pattern { 1 => Integer }
	end

	def test_assert_predicate
		assert_predicate(2, :even?)
	end

	def test_assert_raises
		assert_raises(ArgumentError) { raise ArgumentError.new("Hello") }
	end

	def test_assert_respond_to
		assert_respond_to(String, :new)
	end

	def test_assert_same
		assert_same(1, 1)
	end

	def test_assert_throws
		assert_throws(:foo) { throw :foo }
	end

	def test_refute_empty
		refute_empty([1, 2, 3])
	end

	def test_refute_equal
		refute_equal(1, 2)
	end

	def test_refute_in_delta
		refute_in_delta(1.0, 1.2, 0.1)
	end

	def test_refute_in_epsilon
		refute_in_epsilon(1.0, 1.2, 0.1)
	end

	def test_refute_includes
		refute_includes([1, 2, 3], 4)
	end

	def test_refute_instance_of
		refute_instance_of(String, 1)
	end

	def test_refute_kind_of
		refute_kind_of(String, 1)
	end

	def test_refute_match
		refute_match(/Hello/, "World")
	end

	def test_refute_nil
		refute_nil(1)
	end

	def test_refute_operator
		refute_operator(1, :>, 2)
	end

	def test_refute_path_exists
		refute_path_exists("test/not_a_file.rb")
	end

	def test_refute_pattern
		refute_pattern { 1 => String }
	end

	def test_refute_predicate
		refute_predicate(2, :odd?)
	end

	def test_refute_respond_to
		refute_respond_to(String, :to_i)
	end

	def test_refute_same
		refute_same(1, 2)
	end
end
