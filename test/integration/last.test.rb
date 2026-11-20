# frozen_string_literal: true

require_relative "../support/integration"

class LastTest < Quickdraw::Test
	include Integration

	def failing = project(
		"test/math.test.rb" => <<~RUBY,
			class MathTest < Quickdraw::Test
				test("adds") { assert_equal 3, 1 + 1 }
				test("subtracts") { assert_equal 0, 1 - 1 }
			end
		RUBY
	)

	test "shows an agent the last run's problems a line each, however it was shown at the time", timeout: 20 do
		project = failing
		project.run("--format", "human", "test/math.test.rb")
		last = project.run("last")

		assert last.success?
		assert_match last.stdout, %r{\ARan `\S+ --format human test/math\.test\.rb` \d+s ago\.\n}
		assert_includes last.stdout, "FAILED test/math.test.rb:2 MathTest › adds: Expected 2 · Actual 3\n"
		refute_includes last.stdout, "Expected  2"
		assert_match last.stdout, /^FAILED: 2 tests, 1 passed, 1 failed in /
		assert_match last.stdout, %r{^Details: \S+ last test/math\.test\.rb:2 \(or a whole file\)\. All problems: \S+ last --list$}
	end

	test "shows a problem's details, by its line or its file", timeout: 20 do
		project = failing
		project.run("test/math.test.rb")

		[project.run("last", "test/math.test.rb:2"), project.run("last", "./test/math.test.rb")].each do |details|
			assert details.success?
			assert_includes details.stdout, "FAILED test/math.test.rb:2 MathTest › adds\n  test/math.test.rb:2: "
			assert_includes details.stdout, "Expected  2"
			assert_match details.stdout, %r{Rerun: \S+ test/math\.test\.rb:2$}
		end

		missing = project.run("last", "test/math.test.rb:3")
		assert_equal missing.exit_status, 1
		assert_includes missing.stderr, "The last run had no problem at test/math.test.rb:3."
		match { project.run("last", "--nope") => { exit_status: 2, stderr: /Usage: \S+ last \[PATH\[:LINE\] \| --list\]/ } }
	end

	test "says when no run has been recorded", timeout: 20 do
		project = failing
		project.run("--no-history")
		last = project.run("last")

		assert_equal last.exit_status, 1
		assert_includes last.stderr, "No run has been recorded here."
	end

	test "keeps the run as JSON, with leaks, and quotes a path with a space in the command it suggests", timeout: 20 do
		skip "Leak checks need fork" unless Process.respond_to?(:fork)

		project = project(
			"test/my math.test.rb" => <<~RUBY,
				class MathTest < Quickdraw::Test
					test("adds") { assert_equal 3, 1 + 1 }
					test("forks") { fork { exit!(4) }; sleep 0.2; assert true }
				end
			RUBY
		)

		result = project.run("--format", "agent", "-p", "1")
		assert_includes result.stdout, "Details: #{result.stdout[/^Details: (\S+ last) /, 1]} 'test/my math.test.rb:2'"

		require "json"
		assert JSON.parse(File.read(File.join(project.directory, ".quickdraw/last-run.json")))

		leak = project.run("last", File.join(project.directory, "test/my math.test.rb:3"))
		assert leak.success?
		assert_match leak.stdout, %r{^LEAK test/my math\.test\.rb:3 MathTest › forks: Child process \d+ exited}
		assert_match project.run("last", "--list").stdout, %r{^LEAK test/my math\.test\.rb:3 }
	end

	test "won't let a format write over the kept run", timeout: 20 do
		match { failing.run("--format", "json:.quickdraw/last-run.json") => { exit_status: 2, stderr: /keeps the last run, for `quickdraw last`/ } }
	end
end
