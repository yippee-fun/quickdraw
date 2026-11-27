# frozen_string_literal: true

require_relative "../support/integration"

class PropertiesTest < Quickdraw::Test
	include Integration

	SORTING = <<~RUBY
		class Sorting < Quickdraw::Test
			test "sorts" do
				check(array(integer)) { |list| assert_equal(ENV["QUICKDRAW_FIXTURE_FIXED"] ? list.sort.sort : list, list.sort) }
			end
		end
	RUBY

	test "reports a shrunk counterexample, replays it first next time, and forgets it once it passes", timeout: 30 do
		project = project("sorting.test.rb" => SORTING)
		saved = File.join(project.directory, ".quickdraw/properties")

		result = project.run("-p", "1", "--no-history", "--seed", "1")
		refute result.success?
		assert_includes result.output, "✗ sorting.test.rb:2 Sorting › sorts"
		counterexample = result.output[/Counterexample \(found after \d+ cases?, shrunk \d+ times?\):\n\n    (\[0, -1\]|\[1, 0\])\n\n    Shrunk from:/, 1]
		assert counterexample
		# The case, and a label naming its test, for `quickdraw fuzz --forget`.
		assert_equal Dir.children(saved).size, 2

		result = project.run("-p", "1", "--no-history")
		refute result.success?
		assert_includes result.output, "Counterexample (saved from an earlier run):\n\n    #{counterexample}\n"

		result = project.run("-p", "1", "--no-history", env: { "QUICKDRAW_FIXTURE_FIXED" => "1" })
		assert result.success?
		match { result => { summary: /\A1 test · 1 assertion · / } }
		assert_equal Dir.children(saved), []
	end

	test "--cases-scale checks every property with that many times its cases", timeout: 30 do
		project = project("counting.test.rb" => <<~RUBY)
			class Counting < Quickdraw::Test
				test("ten") { check(integer, cases: 10) { |n| File.write("ten", "x", mode: "a"); assert true } }
				test("three") { check(integer, cases: 3) { |n| File.write("three", "x", mode: "a"); assert true } }
			end
		RUBY

		counts = -> { ["ten", "three"].map { |name| File.size(File.join(project.directory, name)).tap { File.delete(File.join(project.directory, name)) } } }

		assert project.run("-p", "1", "--no-history").success?
		assert_equal counts.(), [10, 3]

		assert project.run("-p", "1", "--no-history", "--cases-scale", "2.5").success?
		assert_equal counts.(), [25, 8]

		assert project.run("-p", "1", "--no-history", "--cases-scale=0.01").success?
		assert_equal counts.(), [1, 1]

		match { project.run("--cases-scale", "0") => { exit_status: 2, stderr: /--cases-scale needs a positive number/ } }
	end

	test "tests with the same description keep their own saved cases", timeout: 30 do
		project = project("same.test.rb" => <<~RUBY)
			class Same < Quickdraw::Test
				test("sorts") { check(array(integer)) { |list| assert_equal list, list.sort } }
				test("sorts") { check(array(integer)) { |list| assert_equal list.sort, list.sort } }
			end
		RUBY
		saved = File.join(project.directory, ".quickdraw/properties")

		refute project.run("-p", "1", "--no-history", "--seed", "1").success?
		assert_equal Dir.children(saved).size, 2

		refute project.run("-p", "1", "--no-history", "--seed", "1").success?
		assert_equal Dir.children(saved).size, 2
	end

	test "the seed repeats a property's cases", timeout: 30 do
		project = project("sorting.test.rb" => SORTING)
		saved = File.join(project.directory, ".quickdraw/properties")

		first = project.run("-p", "2", "--no-history", "--seed", "1234").output[/Shrunk from:\n\n.*$/]
		Quickdraw.remove_tree(saved)
		second = project.run("-p", "2", "--no-history", "--seed", "1234").output[/Shrunk from:\n\n.*$/]

		assert first
		assert_equal second, first
	end
end
