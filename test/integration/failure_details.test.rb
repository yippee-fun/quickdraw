# frozen_string_literal: true

require_relative "../support/integration"

class FailureDetailsTest < Quickdraw::Test
	include Integration

	CONTEXT = <<~RUBY
		class Command < Quickdraw::Test
			test "runs" do
				output = "Running 3 tests\\nFAILED 3 tests"
				context { "exit status 1\\nstderr: no such file" }
				assert_includes output, "PASSED"
			end

			test "raises" do
				context { raise ArgumentError, "no output yet" }
				raise "Output so far:\\nFAILED 3 tests\\rERROR isolated 0"
			end
		end
	RUBY

	test "shows a test's context under its failures, indented with them", timeout: 20 do
		result = project("command.test.rb" => CONTEXT).run("-p", "1", "--no-history", "--format", "human")

		assert_includes result.stdout, %(    "PASSED"\n\n    Context\n      exit status 1\n      stderr: no such file\n)
		assert_includes result.stdout, "  RuntimeError: Output so far:\n    FAILED 3 tests\n    ERROR isolated 0\n"
		assert_includes result.stdout, "    Context\n      context { … } raised ArgumentError: no output yet\n"
		refute_match result.stdout, /^(FAILED 3 tests|ERROR isolated 0|stderr: )/
	end

	test "shows a test's context to agents and in JSON", timeout: 20 do
		project = project("command.test.rb" => CONTEXT)
		agent = project.run("-p", "1", "--no-history", "--format", "agent", "command.test.rb:2")
		json = project.run("-p", "1", "--no-history", "--format", "json")

		assert_includes agent.stdout, "  Context:\n    exit status 1\n    stderr: no such file\n"
		refute_match agent.stdout, /^(FAILED 3 tests|stderr: )/

		runs, raises = json.events.select { |event| event["event"] == "test" }.sort_by { |event| event["line"] }
		assert_equal runs["failures"].first["context"], "exit status 1\nstderr: no such file"
		assert_equal raises["errors"].first["context"], "context { … } raised ArgumentError: no output yet"
	end

	test "shows the first of Quickdraw's frames for an error raised inside it", timeout: 20 do
		result = project("cleanup.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--format", "human")
			class Cleanup < Quickdraw::Test
				test "cleans up" do
					# Called with no path, so it raises inside Quickdraw.
					defer(&Quickdraw.method(:remove_tree))
					assert true
				end
			end
		RUBY

		assert_includes result.stdout, "ArgumentError: wrong number of arguments (given 0, expected 1)"
		assert_includes result.stdout, "Raised inside Quickdraw, whose frames are usually hidden (--backtrace shows them all):"
		assert_match result.stdout, %r{^  \S*lib/quickdraw\.rb:\d+:in .*remove_tree}
	end

	test "shows where a long string comes closest, and all of it when the output isn't a terminal", timeout: 20 do
		result = project("long.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--format", "human")
			class Long < Quickdraw::Test
				test "includes" do
					assert_includes "\#{'ok ' * 300}but nothing matches it\#{' ok' * 300}", "but nothing matched it"
				end
			end
		RUBY

		assert_includes result.stdout, "    Closest match, at line 1, column 901:\n"
		assert_includes result.stdout, %(    - "but nothing matched it"\n    + "but nothing matches it"\n)
		assert_includes result.stdout, "ok ok but nothing matches it ok ok"
		assert_includes result.stdout, %( ok ok"\n)
	end

	test "cuts long values short in a terminal", timeout: 20 do
		skip "Running on a terminal needs PTY" unless terminal?

		result = project("long.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--format", "human", tty: [40, 200], env: { "CI" => nil })
			class Long < Quickdraw::Test
				test("includes") { assert_includes "x" * 1_000, "y" }
			end
		RUBY

		assert_includes result.stdout, "… 502 more characters (shown when the output isn’t a terminal)"
	end

	test "says what the run ran on in CI, but not in a terminal", timeout: 20 do
		project = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n")
		ci = project.run("-p", "1", "--no-history", "--format", "human", "--seed", "7", env: { "CI" => "true" })
		local = project.run("-p", "1", "--no-history", "--format", "human", "--seed", "7", env: { "CI" => nil })

		assert_match ci.stdout, /\A\w+ [\w.-]+ \(.*\) · \d+ cores? · 1 worker · seed 7\n/
		assert_includes ci.stdout, RUBY_PLATFORM
		refute_includes local.stdout, "seed 7"
	end
end
