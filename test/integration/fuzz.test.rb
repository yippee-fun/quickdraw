# frozen_string_literal: true

require "json"
require_relative "../support/integration"

class FuzzIntegrationTest < Quickdraw::Test
	include Integration

	def setup
		super
		skip "fuzz needs fork" unless Process.respond_to?(:fork)
	end

	# Raises only for the words "let x = 42" in that order, which random
	# input almost never makes, but each step along the way reaches a new line.
	LEXER = <<~RUBY
		module Lexer
			def self.run(input)
				state = 0

				input.scan(/[a-z]+|\\d+|=/).each do |word|
					if state == 0 && word == "let"
						state = 1
					elsif state == 1 && word == "x"
						state = 2
					elsif state == 2 && word == "="
						state = 3
					elsif state == 3 && word == "42"
						raise "planted"
					else
						state = 0
					end
				end

				state
			end
		end
	RUBY

	LEXER_TEST = <<~RUBY
		require_relative "../lib/lexer"

		class LexerTest < Quickdraw::Test
			fuzz "lexes anything", bytes(dictionary: ["let", "x", "=", "42"]) do |input|
				Lexer.run(input)
			end

			test "isn't fuzzed unless it's asked for by line" do
				check(integer) { |n| assert Integer === n }
			end
		end
	RUBY

	test "finds a bug only a sequence of tokens reaches, which test runs then replay", timeout: 30 do
		project = project("lib/lexer.rb" => LEXER, "test/lexer.test.rb" => LEXER_TEST)

		# As a property, its 100 cases don't find it.
		assert project.run("-p", "1", "--seed", "1").success?

		result = project.run("fuzz", "--seconds", "3", "-p", "1", "--seed", "1", "--format", "agent")

		assert_equal result.exit_status, 1
		match { result => { stdout: %r{^ERRORED: test/lexer.test.rb:4 LexerTest › lexes anything\. Input \(found after [\d,]+ cases(?:, shrunk \d+ times?)?\):\n"let[^"]*x[^"]*=[^"]*42"\nRuntimeError: planted\nlib/lexer.rb:13:in} } }
		match { result => { stdout: %r{^FUZZED: test/lexer.test.rb:4 LexerTest › lexes anything: [\d,]+ cases in [\d.]+s \([\d,]+/s\) · \d+ edges · \d+ in the corpus · 1 method traced\. Edges: } } }
		refute_includes result.stdout, "isn't fuzzed"
		corpus = Dir.glob("*/*", base: File.join(project.directory, ".quickdraw/fuzz"))
		assert_operator corpus.size, :>, 3

		rerun = project.run("-p", "1", "--format", "agent")
		assert_equal rerun.exit_status, 1
		assert_includes rerun.stdout, "ERROR test/lexer.test.rb:4 LexerTest › lexes anything: RuntimeError: planted"
		match { project.run("last", "test/lexer.test.rb:4") => { stdout: /RuntimeError: planted\nCounterexample \(saved from an earlier run\):\n"let[^"]*x[^"]*=[^"]*42"/ } }
	end

	CRASHES = <<~RUBY
		class CrashTest < Quickdraw::Test
			fuzz "crashes", integer(0..100) do |n|
				Process.kill(:KILL, Process.pid) if n > 50
			end

			fuzz "hangs", integer(0..100) do |n|
				sleep if n == 7
			end
		end
	RUBY

	test "minimises cases that crash or hang the process", timeout: 60 do
		result = project("test/crash.test.rb" => CRASHES).run("fuzz", "--seconds", "1", "--timeout", "0.2", "-p", "1", "--seed", "1", "--format", "agent", timeout: 50)

		assert_equal result.exit_status, 1
		match { result => { stdout: %r{^CRASHED: test/crash.test.rb:2 CrashTest › crashes\. Input \(found after [\d,]+ cases(?:, shrunk \d+ times?)?\):\n51\nThe process was killed by SIGKILL\.$} } }
		match { result => { stdout: %r{^HUNG: test/crash.test.rb:6 CrashTest › hangs\. Input \(found after [\d,]+ cases\):\n7\nA case ran for longer than 0.2s\.$} } }
	end

	test "fuzzes any test that checks a property, given by line, and says when one checks none", timeout: 30 do
		project = project("test/numbers.test.rb" => <<~RUBY)
			class NumbersTest < Quickdraw::Test
				test "a plain property" do
					check(integer(0..1000)) { |n| assert n < 900 }
				end

				test "no property" do
					assert true
				end

				test "a property that discards every case" do
					check(integer.filter { false }) { nil }
				end
			end
		RUBY

		result = project.run("fuzz", "test/numbers.test.rb:2", "test/numbers.test.rb:6", "test/numbers.test.rb:10", "--seconds", "0.5", "-p", "2", "--format", "json")

		assert_equal result.exit_status, 1
		report = JSON.parse(result.stdout)
		test = report.fetch("tests").first

		assert_equal report.fetch("workers"), 2
		assert_equal report.fetch("problems"), [
			"NumbersTest › no property (test/numbers.test.rb:6) checks no property, so there’s nothing to fuzz.",
			"NumbersTest › a property that discards every case (test/numbers.test.rb:10) failed after fuzzing its first property: Quickdraw::Property::Unsatisfiable: Filters discarded all of its cases. Generate fewer values to discard.",
		]
		assert_equal test.slice("path", "line", "name"), { "path" => "test/numbers.test.rb", "line" => 2, "name" => "NumbersTest › a plain property" }
		assert_operator test.fetch("cases"), :>, 0
		assert_equal test.fetch("findings").map { |finding| finding.slice("kind", "input", "failure") }, [
			{ "kind" => "failed", "input" => "900", "failure" => { "message" => "expected false to be truthy", "path" => "test/numbers.test.rb", "line" => 3 } },
		]
	end

	test "--forget deletes the failing cases and corpora kept for the tests in the files given, or every test", timeout: 30 do
		# Fuzzing keeps a corpus for "lexes", and a test run saves a failing case for "fails".
		test_file = lambda do |name|
			<<~RUBY
				require_relative "../lib/lexer"

				class #{name}Test < Quickdraw::Test
					fuzz("lexes", bytes(dictionary: ["let", "x"])) { |input| Lexer.run(input) }
					test("fails") { check(integer(0..100)) { |n| assert n < 50 } }
				end
			RUBY
		end

		project = project("lib/lexer.rb" => LEXER, "test/a.test.rb" => test_file.("A"), "test/b.test.rb" => test_file.("B"))
		project.run("fuzz", "--seconds", "0.5", "-p", "1", "--seed", "1")
		project.run("-p", "1")

		cases = -> { Dir.children(File.join(project.directory, ".quickdraw/properties")).reject { |name| name.include?(".") }.size }
		corpora = -> { Dir.children(File.join(project.directory, ".quickdraw/fuzz")).reject { |name| name.include?(".") }.size }
		assert_equal [cases.(), corpora.()], [2, 2]

		forgotten = project.run("fuzz", "--forget", "test/a.test.rb")
		assert forgotten.success?
		assert_equal forgotten.stdout, "Forgot the failing cases saved for 1 property and the corpora of 1 fuzz test in test/a.test.rb.\n"
		assert_equal [cases.(), corpora.()], [1, 1]
		assert_includes project.run("-p", "1", "--format", "agent").stdout, "Counterexample (saved from an earlier run)"

		# That run saved a's failing case again.
		assert_includes project.run("fuzz", "--forget").stdout, "Forgot the failing cases saved for 2 properties and the corpora of 1 fuzz test."
		assert_equal [cases.(), corpora.()], [0, 0]
		assert_equal project.run("fuzz", "--forget", "test").stdout, "Nothing to forget for test.\n"
		match { project.run("fuzz", "--forget", "test/a.test.rb:2") => { exit_status: 2, stderr: /--forget takes test files or directories, not lines/ } }
	end

	test "says when there's nothing to fuzz" do
		result = project("test/plain.test.rb" => "class PlainTest < Quickdraw::Test\n  test('fuzzy') { assert true }\nend\n").run("fuzz", "--format", "agent")

		assert_equal result.exit_status, 1
		assert_includes result.stdout, "NO TESTS TO FUZZ."
	end
end
