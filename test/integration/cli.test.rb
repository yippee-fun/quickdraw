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

	test "--profile finds a cost that tests share", timeout: 30 do
		result = project("shared.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--profile")
			def build_world = sleep(0.1)

			class Shared < Quickdraw::Test
				test("one") { build_world; assert true }
				test("two") { build_world; assert true }
				test("three") { build_world; assert true }
				test("quick") { assert true }
			end
		RUBY

		assert result.success?
		assert_includes result.stdout, "Where test time goes"
		assert_match result.stdout, /^ +(9\d|100)% +\d+% +3   build_world  shared\.test\.rb:1$/
		# Ruby 3.3 labels it `sleep`.
		assert_match result.stdout, /^ +(9\d|100)% +(9\d|100)% +3   (Kernel#)?sleep  shared\.test\.rb$/
	end

	test "--profile weighs time spent computing and waiting fairly", timeout: 30 do
		skip "On JRuby, in a busy suite, the sampler can miss a computing thread entirely" if RUBY_ENGINE == "jruby"

		result = project("mixed.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--profile")
			def compute
				finish = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.3
				nil while Process.clock_gettime(Process::CLOCK_MONOTONIC) < finish
			end

			def wait = sleep(0.3)

			class Mixed < Quickdraw::Test
				test("both") { compute; wait; assert true }
			end
		RUBY

		shares = result.stdout.scan(/^ +(\d+)% .* (compute|wait)  mixed\.test\.rb:\d+$/).to_h { |share, name| [name, Integer(share)] }
		assert_in_delta shares["compute"], 50, 20
		assert_in_delta shares["wait"], 50, 20
	end

	test "--profile tells apart methods with the same name in different classes", timeout: 30 do
		result = project("setups.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--profile")
			class Slow < Quickdraw::Test
				def setup = sleep(0.2)
				test("a") { assert true }
			end

			class Fast < Quickdraw::Test
				private def setup = sleep(0.05)
				test("b") { assert true }
			end
		RUBY

		assert_match result.stdout, /  setup  setups\.test\.rb:2$/
		assert_match result.stdout, /  setup  setups\.test\.rb:7$/
	end

	test "finishes a run with no test files", timeout: 20 do
		result = project.run("-p", "1", "--no-history")

		assert(result.success?) { result.output }
		match { result => { summary: /\A0 tests · / } }
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
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--seed", "1", "--no-capture", interrupt_when: /started/)
			class A < Quickdraw::Test
				def teardown = puts("tore down")

				test("passes") { assert true }
				test("waits") { puts "started"; sleep 10 }
				test("never starts") { assert true }
			end
		RUBY

		assert_equal result.status.exitstatus, 130
		assert_match result.output, /^INTERRUPTED  /
		assert_includes result.output, "Interrupted  Tests that were running or hadn’t started count as not run.\n"
		assert_includes result.output, "tore down"
		refute_includes result.output, "Quickdraw::Interrupted"
		match { result => { summary: /not run/ } }
	end

	test "Ctrl-C gives teardown a few seconds, then stops what's left", timeout: 20 do
		skip "Stopping a test's teardown needs fork" unless Process.respond_to?(:fork)

		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--no-capture", interrupt_when: /started/)
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

	test "on a terminal, prints a line for each file, lined up, under a status line that's gone at the end", timeout: 20 do
		skip "This Ruby has no PTY" unless terminal?
		skip "The status line needs fork, to capture what tests print" unless Process.respond_to?(:fork)

		result = project(
			"config/quickdraw.rb" => "sleep 0.3\n",
			"a.test.rb" => "class A < Quickdraw::Test; 3.times { |i| test(i.to_s) { sleep 0.2; assert true } }; end\n",
			"models/b.test.rb" => "class B < Quickdraw::Test; test('b') { assert true }; end\n",
		).run("-p", "1", tty: [20, 80])

		assert_match result.stdout, /\r\e\[K\S Booting · \d+\.\ds/
		assert_match result.stdout, %r{\r\e\[K\S [012]/2 files · \d+ tests? · \d+\.\ds}
		# The cursor is hidden while it would cover the spinner, and shown before the summary.
		assert_match result.stdout, /\A\e\[\?25l.*\r\e\[K\e\[\?25h[^\e]*PASSED/m
		screen = result.screen
		assert_match screen, /^✓ a\.test\.rb         3 tests · /
		assert_match screen, %r{^✓ models/b\.test\.rb  1 test · }
		refute_includes screen, "\e["
	end

	test "counts a file with no tests matching a filter as done in the status line", timeout: 20 do
		skip "This Ruby has no PTY" unless terminal?
		skip "The status line needs fork, to capture what tests print" unless Process.respond_to?(:fork)

		result = project(
			"a.test.rb" => "class A < Quickdraw::Test; test('wanted') { sleep 0.3; assert true }; end\n",
			"b.test.rb" => "class B < Quickdraw::Test; test('other') { assert true }; end\n",
		).run("-p", "1", "-n", "wanted", tty: [20, 80])

		frames = result.stdout.scan(%r{\r\e\[K\S (\d+/\d+ files · [^\r]*)\r}).flatten
		assert_match frames.last, %r{\A2/2 files · 1 test · }
	end

	test "doesn't show a status line where it can't be cleared, or with --no-capture", timeout: 20 do
		skip "This Ruby has no PTY" unless terminal?

		project = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { sleep 0.2; assert true }; end\n")

		refute_includes project.run("-p", "1").stdout, "\e[K"
		refute_includes project.run("-p", "1", "--no-capture", tty: [20, 80]).stdout, "\e[K"
		refute_includes project.run("-p", "1", env: { "TERM" => "dumb" }, tty: [20, 80]).stdout, "\e[K"
	end

	test "shortens the status line to fit a narrow terminal, down to the spinner alone", timeout: 20 do
		skip "This Ruby has no PTY" unless terminal?
		skip "The status line needs fork, to capture what tests print" unless Process.respond_to?(:fork)

		project = project("config/quickdraw.rb" => "sleep 0.3\n", "a.test.rb" => "class A < Quickdraw::Test; test('a') { sleep 0.2; assert true }; end\n")

		frames = project.run("-p", "1", tty: [20, 12]).stdout.scan(/\r\e\[K([^\r\n]+)\r(?!\n)/).flatten
		assert frames.any?
		assert(frames.all? { |frame| frame.size <= 9 }) { frames.inspect }
	end

	test "on a terminal, prints what loading a file prints whole, once", timeout: 20 do
		skip "This Ruby has no PTY" unless terminal?

		project = project(
			"a.test.rb" => "class A < Quickdraw::Test; test('waits') { sleep 0.3; assert true }; end\n",
			"b.test.rb" => "puts 'loading b'\nwarn 'warning from b'\nclass B < Quickdraw::Test; test('b') { assert true }; end\n",
		)

		output = project.run("-p", "1", tty: [20, 80]).screen

		assert_equal output.scan("loading b").size, 1
		assert_equal output.scan("warning from b").size, 1
		assert_match output, /^loading b\nwarning from b\n/
	end

	test "shows each problem in full after every file's line, then lists them at the end", timeout: 20 do
		skip "More than one worker needs fork" unless Process.respond_to?(:fork)

		result = project(
			"fails.test.rb" => "class A < Quickdraw::Test; test('fails') { assert false }; end\n",
			"slow.test.rb" => "class B < Quickdraw::Test; test('slow') { sleep 0.5; assert true }; end\n",
		).run("-p", "2", "--no-history")

		assert_match result.stdout, /\A✗ fails\.test\.rb  1 test · .*\n✓ slow\.test\.rb   1 test · .*\n\nFAIL fails  A · fails\.test\.rb:1\n/
		assert_match result.stdout, /^FAILED  .*\n\n  ✗ fails\.test\.rb:1 A › fails\n/
	end
end
