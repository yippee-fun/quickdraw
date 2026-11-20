# frozen_string_literal: true

require_relative "../support/integration"

class ChangedTest < Quickdraw::Test
	include Integration

	def setup
		super
		skip "--coverage needs fork" unless Process.respond_to?(:fork)
	end

	# Report calls Adder and Shout, so its tests run them too.
	def project_with_history = project(
		"lib/adder.rb" => "module Adder\n\tdef self.add(a, b) = a + b\nend\n",
		"lib/shout.rb" => "module Shout\n\tdef self.call(text) = text.upcase\nend\n",
		"lib/report.rb" => "module Report\n\tdef self.call(a, b) = Shout.call(\"total \#{Adder.add(a, b)}\")\nend\n",
		"test/adder.test.rb" => "require_relative '../lib/adder'\nclass AdderTest < Quickdraw::Test; test('adds') { assert_equal Adder.add(1, 2), 3 }; end\n",
		"test/shout.test.rb" => "require_relative '../lib/shout'\nclass ShoutTest < Quickdraw::Test; test('shouts') { assert_equal Shout.call('a'), 'A' }; end\n",
		"test/report.test.rb" => <<~RUBY,
			require_relative "../lib/adder"
			require_relative "../lib/shout"
			require_relative "../lib/report"
			class ReportTest < Quickdraw::Test; test("reports") { assert_equal Report.call(1, 2), "TOTAL 3" }; end
		RUBY
		".gitignore" => ".quickdraw/\n",
	).tap(&:commit)

	test "runs the tests that ran a changed file in the last --coverage run", timeout: 30 do
		project = project_with_history
		# Whichever order they load in, each test file is mapped to what its tests run.
		3.times { |seed| project.run("-p", "1", "--coverage", "--seed", seed.to_s) }
		project.write("lib/shout.rb" => "module Shout\n\tdef self.call(text) = text.upcase.strip\nend\n")

		result = project.run("-p", "1", "--changed", "--format", "agent")

		assert result.success?
		match { result => { stdout: /PASSED: 2 tests, 2 passed/ } }
	end

	test "runs a changed test file", timeout: 30 do
		project = project_with_history
		project.run("-p", "1", "--coverage")
		project.write("test/adder.test.rb" => "require_relative '../lib/adder'\nclass AdderTest < Quickdraw::Test; test('adds again') { assert_equal Adder.add(2, 2), 4 }; end\n")

		match { project.run("-p", "1", "--changed", "--format", "agent") => { stdout: /PASSED: 1 test, 1 passed/ } }
	end

	test "without a map, runs the changed files' counterparts and says so", timeout: 30 do
		project = project_with_history
		project.write("lib/adder.rb" => "module Adder\n\tdef self.add(a, b) = b + a\nend\n")

		result = project.run("-p", "1", "--changed", "--format", "agent")

		assert_includes result.stderr, "No --coverage run has mapped which tests run which files"
		match { result => { stdout: /PASSED: 1 test, 1 passed/ } }
	end

	test "runs everything when config, the Gemfile or a test helper changes", timeout: 30 do
		project = project_with_history
		project.run("-p", "1", "--coverage")
		project.write("test/support/helper.rb" => "# A helper\n")

		result = project.run("-p", "1", "--changed", "--format", "agent")

		assert_includes result.stderr, "Running every test, since test/support/helper.rb changed."
		match { result => { stdout: /PASSED: 3 tests, 3 passed/ } }
	end

	test "says when nothing changed that a test runs", timeout: 30 do
		project = project_with_history
		project.run("-p", "1", "--coverage")
		project.write("README.md" => "# Hello\n", "lib/unused.rb" => "module Unused; end\n")

		result = project.run("-p", "1", "--changed", "--format", "agent")

		assert result.success?
		assert_includes result.stderr, "Coverage only maps Ruby, so tests that use README.md may not run."
		assert_includes result.stderr, "Nothing has changed that any test runs."
	end

	test "a coverage run of some of a file's tests adds to its map, rather than replacing it", timeout: 30 do
		project = project_with_history
		project.write("test/report.test.rb" => <<~RUBY)
			require_relative "../lib/adder"
			require_relative "../lib/shout"
			class ReportTest < Quickdraw::Test
				test("adds") { assert_equal Adder.add(1, 2), 3 }
				test("shouts") { assert_equal Shout.call("a"), "A" }
			end
		RUBY
		project.commit
		project.run("-p", "1", "--coverage")
		project.run("-p", "1", "--coverage", "--name", "adds")
		project.write("lib/shout.rb" => "module Shout\n\tdef self.call(text) = text.upcase.strip\nend\n")

		match { project.run("-p", "1", "--changed", "--format", "agent") => { stdout: /PASSED: 3 tests, 3 passed/ } }
	end

	test "runs everything when a file that only loads with config changes", timeout: 30 do
		project = project_with_history
		project.write("config/quickdraw.rb" => "require_relative '../lib/settings'\n", "lib/settings.rb" => "SETTING = 1\n")
		project.commit
		project.run("-p", "1", "--coverage")
		project.write("lib/settings.rb" => "SETTING = 2\n")

		result = project.run("-p", "1", "--changed", "--format", "agent")

		assert_includes result.stderr, "Running every test, since lib/settings.rb changed, which loads with config but no test runs its code."
		match { result => { stdout: /PASSED: 3 tests, 3 passed/ } }
	end

	test "runs the tests of a renamed file's old name", timeout: 30 do
		project = project_with_history
		project.run("-p", "1", "--coverage")
		project.git("mv", "lib/shout.rb", "lib/yell.rb")

		result = project.run("-p", "1", "--changed", "--format", "agent")
		assert_match result.stdout, %r{^2 × ERROR LoadError: cannot load such file -- .+, such as test/\w+\.test\.rb could not be loaded$}

		problems = project.run("last", "--list").stdout
		assert_includes problems, "ERROR test/report.test.rb could not be loaded"
		assert_includes problems, "ERROR test/shout.test.rb could not be loaded"
	end

	test "without history, runs the changed files' counterparts", timeout: 30 do
		project = project_with_history
		project.write("lib/adder.rb" => "module Adder\n\tdef self.add(a, b) = b + a\nend\n")

		match { project.run("-p", "1", "--changed", "--no-history", "--format", "agent") => { stdout: /PASSED: 1 test, 1 passed/ } }
	end

	test "--base runs the tests for what changed since the branch left REF, committed or not", timeout: 30 do
		project = project_with_history
		project.git("switch", "--quiet", "-c", "feature")
		project.write("lib/adder.rb" => "module Adder\n\tdef self.add(a, b) = b + a\nend\n")
		project.commit
		project.git("switch", "--quiet", "main")
		project.write("lib/shout.rb" => "module Shout\n\tdef self.call(text) = text.upcase.strip\nend\n")
		project.commit
		project.git("switch", "--quiet", "feature")

		match { project.run("-p", "1", "--changed", "--format", "agent") => { stderr: /Nothing has changed/ } }
		match { project.run("-p", "1", "--changed", "--base", "main", "--format", "agent") => { stdout: /PASSED: 1 test, 1 passed/ } }

		project.write("lib/yell.rb" => "module Yell; end\n", "test/adder.test.rb" => "require_relative '../lib/adder'\nclass AdderTest < Quickdraw::Test; test('adds') { assert_equal Adder.add(1, 2), 3 }; test('adds more') { assert_equal Adder.add(2, 2), 4 }; end\n")
		match { project.run("-p", "1", "--changed", "--base", "main", "--format", "agent") => { stdout: /PASSED: 2 tests, 2 passed/ } }
	end

	test "--base explains when it can't be used", timeout: 20 do
		project = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n")
		project.commit

		match { project.run("--base", "main") => { stderr: /--base says what --changed compares with, so it needs --changed\./, exit_status: 2 } }
		match { project.run("--changed", "--base", "nope") => { stderr: /Git can’t find/, exit_status: 2 } }
	end

	test "explains when --changed can't be used", timeout: 20 do
		project = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n")

		match { project.run("--changed") => { stderr: /--changed needs a git repository/ } }
		match { project.run("--changed", "a.test.rb") => { stderr: /can’t be used with paths/, exit_status: 2 } }
		match { project.run("--changed", "--watch") => { stderr: /can’t be used with --watch/, exit_status: 2 } }
		match { project.run("--changed", "--failed") => { stderr: /can’t be used with --failed/, exit_status: 2 } }
	end
end
