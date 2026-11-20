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
		match { project.run("last", "--nope") => { exit_status: 2, stderr: /Usage: \S+ last \[--from FILE\] \[PATH\[:LINE\] \| --list\]/ } }
		match { project.run("last", "") => { exit_status: 2, stderr: /Usage: / } }
	end

	test "says when no run has been recorded", timeout: 20 do
		project = failing
		project.run("--no-history")
		last = project.run("last")

		assert_equal last.exit_status, 1
		assert_includes last.stderr, "No run has been recorded here."
	end

	test "keeps the run as JSON Lines, with leaks, and quotes a path with a space in the command it suggests", timeout: 20 do
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
		assert(File.readlines(File.join(project.directory, ".quickdraw/last-run.jsonl")).all? { |line| JSON.parse(line) })

		leak = project.run("last", File.join(project.directory, "test/my math.test.rb:3"))
		assert leak.success?
		assert_match leak.stdout, %r{^LEAK test/my math\.test\.rb:3 MathTest › forks: Child process \d+ exited}
		assert_match project.run("last", "--list").stdout, %r{^LEAK test/my math\.test\.rb:3 }
	end

	test "keeps each problem in full, with how, where and on what the run ran", timeout: 20 do
		project = project(
			"test/math.test.rb" => <<~RUBY,
				class MathTest < Quickdraw::Test
					test("adds") { puts "adding"; assert_equal 3, 1 + 1 }
					test("divides") { 1 / 0 }
				end
			RUBY
		)
		project.run("-p", "1", "--seed", "42", "test/math.test.rb")

		require "json"
		start, *problems, finish = File.readlines(File.join(project.directory, Quickdraw::Reporters::LastRun::PATH)).map { |line| JSON.parse(line, symbolize_names: true) }
		adds, divides = problems.sort_by { |problem| problem.dig(:test, :line) }

		match do
			start => {
				event: "start", format: Quickdraw::Reporters::LastRun::FORMAT, quickdraw: String, ruby: /\A#{RUBY_ENGINE}/, platform: RUBY_PLATFORM,
				directory: String, command: %r{ --seed 42 test/math\.test\.rb\z}, arguments: ["-p", "1", "--seed", "42", "test/math.test.rb"], seed: 42, started_at: Float,
			}
		end
		match { adds => { event: "result", path: "test/math.test.rb", test: { line: 2 }, result: { failures: [{ message: /Expected.*2/m }] }, rerun: %r{ test/math\.test\.rb:2\z} } }
		match { divides => { event: "result", result: { errors: [{ name: "ZeroDivisionError", message: "divided by 0", backtrace: [*, /math\.test\.rb:3/, *] }] }, rerun: %r{ test/math\.test\.rb:3\z} } }
		match { finish => { event: "finish", finished_at: Float, outcome: { "@failed": 1, "@errored": 1 } } }
		# Without fork, what tests print isn't captured.
		assert_equal adds.dig(:result, :output), "adding\n" if Process.respond_to?(:fork)
	end

	test "reads a run kept elsewhere, such as a CI artifact, with its paths as they are here", timeout: 20 do
		ci = failing
		ci.run("test/math.test.rb")

		local = failing
		kept = File.join(local.directory, "artifact", "last-run.jsonl")
		Dir.mkdir(File.dirname(kept))
		File.rename(File.join(ci.directory, Quickdraw::Reporters::LastRun::PATH), kept)

		match { local.run("last") => { exit_status: 1, stderr: /No run has been recorded here/ } }

		summary = local.run("last", "--from", "artifact/last-run.jsonl")
		assert summary.success?
		assert_includes summary.stdout, "FAILED test/math.test.rb:2 MathTest › adds: Expected 2 · Actual 3\n"
		assert_match summary.stdout, %r{^Details: \S+ last --from artifact/last-run\.jsonl test/math\.test\.rb:2 \(or a whole file\)\. All problems: \S+ last --from artifact/last-run\.jsonl --list$}
		refute_includes summary.stdout, "--failed"

		details = local.run("last", "test/math.test.rb:2", "--from=artifact/last-run.jsonl")
		assert details.success?
		assert_includes details.stdout, "  test/math.test.rb:2: test(\"adds\") { assert_equal 3, 1 + 1 }\n"
		refute_includes details.stdout, ci.directory

		assert_match local.run("last", "--from", kept, "--list").stdout, %r{^FAILED test/math\.test\.rb:2 }
		match { local.run("last", "--from", "missing.jsonl") => { exit_status: 1, stderr: /There’s no missing\.jsonl\./ } }
		match { local.run("last", "--from", "artifact") => { exit_status: 1, stderr: /Couldn’t read artifact / } }
		match { local.run("last", "--from") => { exit_status: 2, stderr: /Usage: / } }
	end

	test "won't read a run another version of Quickdraw kept differently", timeout: 20 do
		project = failing
		project.write(
			"older.json" => %({"command":"qd","results":[],"load_errors":[]}\n),
			"newer.jsonl" => %({"event":"start","format":#{Quickdraw::Reporters::LastRun::FORMAT + 1},"quickdraw":"9.0.0"}\n),
		)

		match { project.run("last", "--from", "older.json") => { exit_status: 1, stderr: /older\.json was kept by an older Quickdraw, which keeps runs differently/ } }
		match { project.run("last", "--from", "newer.jsonl") => { exit_status: 1, stderr: /newer\.jsonl was kept by Quickdraw 9\.0\.0, which keeps runs differently/ } }
	end

	test "keeps what a run found before it was killed", timeout: 20 do
		skip "Without fork, one worker could run the hanging test first" unless Process.respond_to?(:fork)

		project = project(
			"test/fails.test.rb" => "class FailsTest < Quickdraw::Test; test('fails') { assert false }; end\n",
			"test/hangs.test.rb" => <<~RUBY,
				class HangsTest < Quickdraw::Test
					test("hangs") do
						sleep 0.05 until File.read("#{Quickdraw::Reporters::LastRun::PATH}").include?('"event":"result"')
						sleep 30
					end
				end
			RUBY
		)
		assert_raises(RuntimeError) { project.run("-p", "2", "--retry", "0", timeout: 5) }

		last = project.run("last")
		assert last.success?
		assert_match last.stdout, /\AStarted `\S+ -p 2 --retry 0` \d+s ago, and hasn’t finished: it’s still running, or was stopped or crashed, having found 1 problem\.\n/
		assert_includes last.stdout, "FAILED test/fails.test.rb:1 FailsTest › fails"
	end

	test "won't let a format write over the kept run", timeout: 20 do
		match { failing.run("--format", "json:.quickdraw/last-run.jsonl") => { exit_status: 2, stderr: /keeps the last run, for `quickdraw last`/ } }
	end
end
