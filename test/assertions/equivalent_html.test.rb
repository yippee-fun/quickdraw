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

	test "#assert_equivalent_html compares comments and handles wbr" do
		assert_test(passes: 1) do
			assert_equivalent_html "<div><!-- note -->a<wbr>b</div>", "<div>\n  <!-- note -->\n  a<wbr>b\n</div>"
		end

		assert_test(failures: 1) do
			assert_equivalent_html "<div><!-- note -->a</div>", "<div><!-- other -->a</div>"
		end

		assert_test(failures: 1) do
			assert_equivalent_html "<div><!-- note -->a</div>", "<div>a</div>"
		end

		assert_equal(
			Quickdraw::HTMLPrettifier.prettify(Nokogiri::HTML4.fragment("<div>a<wbr>b</div>")),
			Quickdraw::HTMLPrettifier.prettify("<div>a<wbr>b</div>"),
		)
	end
end
