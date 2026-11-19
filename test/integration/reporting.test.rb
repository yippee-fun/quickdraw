# frozen_string_literal: true

require_relative "../support/integration"

class ReportingTest < Quickdraw::Test
	include Integration

	test "exits successfully with a summary and a rerun command when everything passes", timeout: 20 do
		result = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n").run("-p", "1", "--no-history", "--seed", "7")

		assert result.success?
		match { result => { summary: /\A1 test · 1 assertion · / } }
		assert_match result.output, /^Seed 7 · 1 worker \(manual\) · (bundle exec )?quickdraw --seed 7$/
	end

	test "reports failures with the failing line, then exits unsuccessfully", timeout: 20 do
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history")
			class A < Quickdraw::Test
				test("compares strings") do
					assert_equal "hello\\nworld", "hello\\nthere"
				end
			end
		RUBY

		refute result.success?
		assert_includes result.output, "✗ a.test.rb:2 A › compares strings"
		assert_includes result.output, "a.test.rb:3"
		assert_includes result.output, "- there\n    + world"
	end

	test "shows only the test's frames in an error's backtrace", timeout: 20 do
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history")
			class A < Quickdraw::Test
				test("raises inside an assertion") do
					assert_includes nil, 1
				end
			end
		RUBY

		assert_includes result.output, "NoMethodError"
		assert_includes result.output, "a.test.rb:3"
		refute_includes result.output, "lib/quickdraw"
		refute_includes result.output, "exe/"
	end

	test "reports a file that fails to load", timeout: 20 do
		result = project("broken.test.rb" => "raise 'broken'\n").run("-p", "1", "--no-history")

		refute result.success?
		assert_includes result.output, "✗ broken.test.rb could not be loaded"
		assert_includes result.output, "RuntimeError: broken"
	end

	test "lists the slowest tests and files with --timings", timeout: 20 do
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--timings")
			class A < Quickdraw::Test
				test("slow") { sleep 0.05; assert true }
				test("fast") { assert true }
			end
		RUBY

		assert_includes result.output, "Slowest tests"
		assert_includes result.output, "Slowest files"
		assert_match result.output, /^\s+\d+(\.\d+)?ms\s+a\.test\.rb:2 A › slow/
	end
end
