# frozen_string_literal: true

class EqualHTMLTest < Quickdraw::Test
	test "#assert_equal_html pass" do
		assert_test(passes: 1) do
			assert_equal_html "<div>Hello</div>", "<div>Hello</div>"
		end
	end

	test "#assert_equal_html failure" do
		assert_test(failures: 1) do
			assert_equal_html "<div>Hello</div>", "<div>World</div>"
		end
	end

	test "#assert_equal_html raises ArgumentError when actual is not a string" do
		assert_raises(ArgumentError) do
			assert_equal_html 123, "<div>Hello</div>"
		end
	end

	test "#assert_equal_html raises ArgumentError when expected is not a string" do
		assert_raises(ArgumentError) do
			assert_equal_html "<div>Hello</div>", 123
		end
	end
end
