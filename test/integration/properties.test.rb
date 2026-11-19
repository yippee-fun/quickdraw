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
		assert_equal Dir.children(saved).size, 1

		result = project.run("-p", "1", "--no-history")
		refute result.success?
		assert_includes result.output, "Counterexample (saved from an earlier run):\n\n    #{counterexample}\n"

		result = project.run("-p", "1", "--no-history", env: { "QUICKDRAW_FIXTURE_FIXED" => "1" })
		assert result.success?
		match { result => { summary: /\A1 test · 1 assertion · / } }
		assert_equal Dir.children(saved), []
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
