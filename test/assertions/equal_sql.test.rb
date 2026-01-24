# frozen_string_literal: true

class EqualSqlTest < Quickdraw::Test
	test "#assert_equal_sql pass" do
		assert_test(passes: 1) do
			assert_equal_sql "SELECT * FROM users", "SELECT * FROM users"
		end
	end

	test "#assert_equal_sql failure" do
		assert_test(failures: 1) do
			assert_equal_sql "SELECT * FROM users", "SELECT * FROM posts"
		end
	end

	test "#assert_equal_sql raises ArgumentError when actual is not a string" do
		assert_raises(ArgumentError) do
			assert_equal_sql 123, "SELECT * FROM users"
		end
	end

	test "#assert_equal_sql raises ArgumentError when expected is not a string" do
		assert_raises(ArgumentError) do
			assert_equal_sql "SELECT * FROM users", 123
		end
	end
end
