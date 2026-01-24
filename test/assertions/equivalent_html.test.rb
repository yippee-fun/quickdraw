# frozen_string_literal: true

class EquivalentHtmlTest < Quickdraw::Test
	test "#assert_equivalent_html pass with identical HTML" do
		assert_test(passes: 1) do
			assert_equivalent_html "<div>Hello</div>", "<div>Hello</div>"
		end
	end

	test "#assert_equivalent_html pass with equivalent HTML (different whitespace)" do
		assert_test(passes: 1) do
			assert_equivalent_html "<div>  Hello  </div>", "<div>Hello</div>"
		end
	end

	test "#assert_equivalent_html pass with equivalent HTML (different formatting)" do
		assert_test(passes: 1) do
			assert_equivalent_html "<div><span>Hello</span></div>", "<div>\n\t<span>Hello</span>\n</div>"
		end
	end

	test "#assert_equivalent_html fail with different HTML" do
		assert_test(failures: 1) do
			assert_equivalent_html "<div>Hello</div>", "<div>Goodbye</div>"
		end
	end

	test "#assert_equivalent_html fail with different structure" do
		assert_test(failures: 1) do
			assert_equivalent_html "<div><span>Hello</span></div>", "<div>Hello</div>"
		end
	end
end
