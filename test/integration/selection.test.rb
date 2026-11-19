# frozen_string_literal: true

require_relative "../support/integration"

class SelectionTest < Quickdraw::Test
	include Integration

	SOURCE = <<~RUBY
		class Maths < Quickdraw::Test
			test "adds" do
				assert_equal 1 + 1, 2
			end

			test "subtracts" do
				assert_equal 2 - 1, 1
			end

			test "multiplies" do
				assert_equal 2 * 3, 6
			end
		end
	RUBY

	def maths = project("maths.test.rb" => SOURCE)

	test "runs the test containing a line", timeout: 20 do
		result = maths.run("-p", "1", "--no-history", "maths.test.rb:7")

		assert result.success?
		match { result => { summary: /\A1 test · 1 assertion/ } }
	end

	test "runs the tests containing each of several lines", timeout: 20 do
		result = maths.run("-p", "1", "--no-history", "maths.test.rb:3:10")

		match { result => { summary: /\A2 tests · 2 assertions/ } }
	end

	test "runs tests whose name contains a string, or matches a regex", timeout: 20 do
		match { maths.run("-p", "1", "--no-history", "-n", "subtracts") => { summary: /\A1 test · / } }
		match { maths.run("-p", "1", "--no-history", "-n", "/^Maths › (adds|multiplies)$/") => { summary: /\A2 tests · / } }
		match { maths.run("-p", "1", "--no-history", "-n", "/ADDS/i") => { summary: /\A1 test · / } }
	end

	test "skips excluded tests, combined with other filters", timeout: 20 do
		match { maths.run("-p", "1", "--no-history", "-x", "adds") => { summary: /\A2 tests · / } }
		match { maths.run("-p", "1", "--no-history", "-n", "/s$/", "-x", "adds") => { summary: /\A2 tests · / } }
		match { maths.run("-p", "1", "--no-history", "maths.test.rb:3:7", "-x", "adds") => { summary: /\A1 test · / } }
	end

	test "fails when filters match nothing, rather than passing silently", timeout: 20 do
		result = maths.run("-p", "1", "--no-history", "-n", "divides")

		refute result.success?
		assert_includes result.output, "No tests matched"
	end

	test "warns about a line no test starts at or above", timeout: 20 do
		result = maths.run("-p", "1", "--no-history", "maths.test.rb:1")

		refute result.success?
		assert_includes result.output, "No test starts at or above maths.test.rb:1."
	end

	test "selects every test that starts on the nearest line", timeout: 20 do
		result = project("same_line.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "same_line.test.rb:2")
			class SameLine < Quickdraw::Test
				test("first") { assert true }; test("second") { assert true }
				test("third") { assert true }
			end
		RUBY

		match { result => { summary: /\A2 tests · / } }
	end

	test "fails when a path matches no file", timeout: 20 do
		result = maths.run("-p", "1", "--no-history", "math.test.rb:12")

		assert_equal result.status.exitstatus, 2
		assert_includes result.stderr, "Error: math.test.rb:12 doesn’t exist.\nDid you mean maths.test.rb:12?"
	end

	test "runs a file once when it's given by two paths", timeout: 20 do
		project = maths
		result = project.run("-p", "1", "--no-history", "maths.test.rb", File.join(project.directory, "maths.test.rb"))

		match { result => { summary: /\A3 tests · / } }
	end

	test "uses a path with glob characters as a file, not a glob", timeout: 20 do
		result = project(
			"a[1].test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n",
			"a1.test.rb" => "class B < Quickdraw::Test; test('b') { assert true }; test('c') { assert true }; end\n",
		).run("-p", "1", "--no-history", "a[1].test.rb")

		match { result => { summary: /\A1 test · / } }
	end

	test "explains an invalid --name regex", timeout: 20 do
		result = maths.run("-p", "1", "--no-history", "-n", "/[/")

		assert_equal result.status.exitstatus, 2
		assert_includes result.stderr, "Error: /[/ isn’t a valid pattern: premature end of char-class: /[/."
		refute_includes result.stderr, ".rb:"
	end

	test "--fail-fast stops promptly after a problem in the middle of a file", timeout: 20 do
		result = project("middle.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--fail-fast", "middle.test.rb")
			class Middle < Quickdraw::Test
				20.times { |i| test("passes \#{i}") { puts "ran passes \#{i}"; assert true } }
				test("fails") { puts "ran fails"; assert false }
				20.times { |i| test("passes again \#{i}") { puts "ran passes again \#{i}"; assert true } }
			end
		RUBY

		refute result.success?
		assert_equal result.stdout.scan(/^ran .*$/).last, "ran fails"
		match { result => { summary: /not run/ } }
	end

	test "--fail-fast stops starting tests after the first problem", timeout: 20 do
		result = project("many.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--fail-fast", "many.test.rb")
			class Many < Quickdraw::Test
				50.times { |i| test("t\#{i}") { assert false } }
			end
		RUBY

		refute result.success?
		assert_includes result.output, "Stopped after the first problem (--fail-fast)."
		assert_match result.summary, /not run/
	end
end
