# frozen_string_literal: true

require_relative "../support/integration"

class CLITest < Quickdraw::Test
	include Integration

	def passing = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n")

	test "explains an unknown option and suggests the one meant, without a backtrace", timeout: 20 do
		result = passing.run("--nmae", "x")

		assert_equal result.status.exitstatus, 2
		assert_includes result.stderr, "Error: --nmae isn’t an option.\nDid you mean --name?\n"
		assert_includes result.stderr, "--help for usage."
		refute_includes result.stderr, ".rb:"
	end

	test "explains ambiguous options and bad values", timeout: 20 do
		match { passing.run("--fail") => { stderr: /Did you mean --failed or --fail-fast\?/ } }
		match { passing.run("-p", "abc") => { stderr: /--processes takes a whole number, not "abc"\./ } }
		match { passing.run("-p") => { stderr: /--processes needs a value, as in --processes N\./ } }
		match { passing.run("--format", "jsn") => { stderr: /jsn isn’t a format\. Use human, agent, json or junit\.\nDid you mean json\?/ } }
		match { passing.run("--format", "json", "--format", "agent") => { stderr: /Only one format can write to the terminal\./ } }
	end

	test "explains report destinations it can't use", timeout: 20 do
		project = project("a.test.rb" => "", "reports/.keep" => "")

		match { project.run("--format", "json:r", "--format", "junit:./r") => { stderr: %r{More than one format would write to .*/r\.\n} } }
		match { project.run("--format", "json:reports") => { stderr: /reports is a directory, so a report can’t be written to it\./ } }
		match { project.run("--format", "json:") => { stderr: /--format json: needs a file after the colon\./ } }
		match { project.run("--watch", "--format", "junit") => { stderr: /--watch would write a JUnit document to the terminal on every run\./ } }
	end

	test "writes several formats at once, with the default on the terminal", timeout: 20 do
		project = passing
		result = project.run("-p", "1", "--no-history", "--format", "json:out.json", "--format", "junit:reports/junit.xml")

		match { result => { summary: /\A1 test · 1 assertion/ } }
		assert_includes File.read(File.join(project.directory, "out.json")), %("event":"finish")
		assert_includes File.read(File.join(project.directory, "reports/junit.xml")), %(tests="1")
	end

	test "runs the test files in a directory, and suggests one for a typo", timeout: 20 do
		project = project(
			"test/models/user.test.rb" => "class U < Quickdraw::Test; test('u') { assert true }; end\n",
			"test/other.test.rb" => "class O < Quickdraw::Test; test('o') { assert true }; end\n",
		)

		match { project.run("-p", "1", "--no-history", "test/models") => { summary: /\A1 test · / } }

		typo = project.run("-p", "1", "--no-history", "test/model")
		assert_equal typo.status.exitstatus, 2
		assert_includes typo.stderr, "Error: test/model doesn’t exist.\nDid you mean test/models?"
	end

	test "--help groups options and shows examples", timeout: 20 do
		result = passing.run("--help")

		assert result.success?
		assert_includes result.stdout, "Choosing tests\n"
		assert_includes result.stdout, "Workers\n"
		assert_includes result.stdout, "Examples\n"
	end

	test "--version", timeout: 20 do
		assert_equal passing.run("--version").stdout, "Quickdraw #{Quickdraw::VERSION}\n"
	end

	test "Ctrl-C stops the run, runs teardown and reports what finished", timeout: 20 do
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--seed", "1", interrupt_when: /started/)
			class A < Quickdraw::Test
				def teardown = puts("tore down")

				test("passes") { assert true }
				test("waits") { puts "started"; sleep 10 }
				test("never starts") { assert true }
			end
		RUBY

		assert_equal result.status.exitstatus, 130
		assert_includes result.output, "Interrupted."
		assert_includes result.output, "tore down"
		refute_includes result.output, "Quickdraw::Interrupted"
		match { result => { summary: /not run/ } }
	end

	test "Ctrl-C gives teardown a few seconds, then stops what's left", timeout: 20 do
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history", interrupt_when: /started/)
			class A < Quickdraw::Test
				def teardown = sleep(30)

				test("waits") { puts "started"; sleep 30 }
			end
		RUBY

		assert_equal result.status.exitstatus, 130
		assert_operator result.duration, :<, 10
		refute_includes result.output, "WorkerCrashed"
		match { result => { summary: /\A0 tests · 0 assertions · 1 not run/ } }
	end

	test "on a terminal, keeps a progress bar on the bottom row, then gives the row back", timeout: 20 do
		project = project("a.test.rb" => "class A < Quickdraw::Test; 3.times { |i| test(i.to_s) { sleep 0.2; assert true } }; end\n")
		project.run("-p", "1")
		result = project.run("-p", "1", tty: [10, 60])

		assert_includes result.stdout, "\e[1;9r"
		assert_match result.stdout, %r{\e\[10;1H\e\[2K━*─* \d/3 tests}
		assert result.stdout.index("\e[r") < result.stdout.index("3 tests · 3 assertions")
	end

	test "reports a problem as it happens, then lists them all at the end", timeout: 20 do
		result = project(
			"fails.test.rb" => "class A < Quickdraw::Test; test('fails') { assert false }; end\n",
			"slow.test.rb" => "class B < Quickdraw::Test; test('slow') { sleep 0.5; puts 'slow finished'; assert true }; end\n",
		).run("-p", "2", "--no-history")

		failure = result.stdout.index("✗ fails.test.rb:1 A › fails")
		assert_operator failure, :<, result.stdout.index("slow finished")
		assert_includes result.stdout, "1 problem\n  ✗ fails.test.rb:1 A › fails\n"
	end
end
