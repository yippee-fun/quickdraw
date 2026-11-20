# frozen_string_literal: true

require_relative "../support/integration"

class FormatsTest < Quickdraw::Test
	include Integration

	SHAPES = <<~RUBY
		class Shapes < Quickdraw::Test
			def area(width, height) = width * height

			test "computes area" do
				assert_equal area(2, 3), 7
			end

			test "raises in a helper" do
				area(nil, 3)
			end

			test "passes" do
				assert true
			end
		end
	RUBY

	def shapes = project("shapes.test.rb" => SHAPES)

	test "uses the agent format under an AI coding agent, a line per problem, with details a command away", timeout: 20 do
		project = shapes
		result = project.run("-p", "1", env: { "CLAUDECODE" => "1" })

		refute result.success?
		assert_match result.output, /^FAILED shapes\.test\.rb:4 Shapes › computes area: Expected \d+ · Actual \d+$/
		assert_match result.output, /^ERROR shapes\.test\.rb:8 Shapes › raises in a helper: \w+Error: /
		refute_includes result.output, "shapes.test.rb:5: assert_equal area(2, 3), 7"
		assert_match result.output, /^FAILED: 3 tests, 1 passed, 1 failed, 1 errored in [\d.]+s \(seed \d+\)$/
		assert_match result.output, /^Details: \S+ last shapes\.test\.rb:\d+ \(or a whole file\)\./
		refute_includes result.output, "\e["

		details = project.run("last", "shapes.test.rb:8").stdout
		assert_includes details, "ERROR shapes.test.rb:8 Shapes › raises in a helper"
		assert_includes details, "shapes.test.rb:2: def area(width, height) = width * height"
	end

	test "shows the first problem in full when the run isn't kept for details", timeout: 20 do
		result = shapes.run("-p", "1", "--no-history", "--format", "agent")

		# Whichever ran first, which depends on the seed.
		assert_equal result.output.scan(/^  Rerun: /).size, 1
		assert_match result.output, /^FAILED shapes\.test\.rb:4 Shapes › computes area: /
		assert_match result.output, /^ERROR shapes\.test\.rb:8 Shapes › raises in a helper: /
		refute_includes result.output, "Details:"
	end

	test "keeps the agent format to one line when everything passes", timeout: 20 do
		result = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n").run("-p", "1", "--no-history", "--format", "agent")

		assert result.success?
		assert_match result.stdout, /\APASSED: 1 test, 1 passed in [\d.]+s \(seed \d+\)\n\z/
	end

	test "groups problems with the same cause, and counts causes past the first 20, for agents", timeout: 20 do
		project = project("many.test.rb" => <<~RUBY)
			class Many < Quickdraw::Test
				15.times { |i| test("fails \#{i}") { nil.name } }
				25.times { |i| test("differs \#{i}") { raise "cause \#{i}" } }
			end
		RUBY
		result = project.run("-p", "1", "--format", "agent")

		# Ruby 3.3 quotes the method with a backtick.
		assert_match result.output, /^15 × ERROR NoMethodError: undefined method [`']name' for nil, such as many\.test\.rb:\d+ Many › fails \d+$/
		assert_equal result.output.scan(/^ERROR many\.test\.rb:\d+ Many › differs \d+: RuntimeError: cause \d+$/).size, 19
		assert_includes result.output, "and 6 more causes, across 6 problems"
		assert_equal project.run("last", "--list").stdout.lines.count { |line| line.match?(/^(?:FAILED|ERROR) /) }, 40
	end

	test "streams one JSON event per line", timeout: 20 do
		require "json"
		result = shapes.run("-p", "1", "--no-history", "--format", "json")
		events = result.stdout.lines.map { |line| JSON.parse(line, symbolize_names: true) }

		assert_equal events.first[:event], "start"
		assert_equal events.count { |event| event[:event] == "test" }, 3
		match { events.last => { event: "finish", passed: false, tests: 3, failed: 1, errored: 1 } }

		failure = events.find { |event| event[:name] == "Shapes › computes area" }
		match { failure => { status: "failed", line: 4, failures: [{ path: "shapes.test.rb", line: 5 }] } }
	end

	test "keeps the JSON stream valid when tests print, sending their output to stderr", timeout: 20 do
		require "json"
		result = project("noisy.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--no-capture", "--format", "json")
			class Noisy < Quickdraw::Test
				test("prints") { puts "debugging"; system("echo", "from a subprocess"); assert true }
			end
		RUBY

		result.stdout.lines.each { |line| JSON.parse(line) }
		assert_includes result.stderr, "debugging"
		assert_includes result.stderr, "from a subprocess"
	end

	test "puts what a failing test printed in its JSON event and JUnit testcase", timeout: 20 do
		skip "Capturing what tests print needs fork" unless Process.respond_to?(:fork)

		require "json"
		project = project("noisy.test.rb" => <<~RUBY)
			puts "loading"

			class Noisy < Quickdraw::Test
				test("fails") { puts "debugging"; system("echo", "from a subprocess"); assert false }
				test("passes") { puts "quiet"; assert true }
			end
		RUBY

		result = project.run("-p", "1", "--no-history", "--format", "json", "--format", "junit:junit.xml")
		events = result.stdout.lines.map { |line| JSON.parse(line, symbolize_names: true) }

		match { events.find { |event| event[:name] == "Noisy › fails" } => { output: "debugging\nfrom a subprocess\n" } }
		match { events.find { |event| event[:name] == "Noisy › passes" } => { output: nil } }
		assert_includes result.stderr, "loading"
		refute_includes result.output, "quiet"
		assert_includes File.read(File.join(project.directory, "junit.xml")), "<system-out>debugging\nfrom a subprocess\n</system-out>"
	end

	test "reports invalid UTF-8 and binary messages without crashing", timeout: 20 do
		require "json"
		project = project("binary.test.rb" => <<~RUBY)
			class Binary < Quickdraw::Test
				test("raises binary") { raise "\\xff".b }
				test("fails with invalid UTF-8") { assert(false) { "bad \\xff".dup.force_encoding("UTF-8") } }
			end
		RUBY

		json = project.run("-p", "1", "--no-history", "--format", "json", "--format", "junit:junit.xml")
		match { JSON.parse(json.stdout.lines.last, symbolize_names: true) => { event: "finish", failed: 1, errored: 1 } }
		assert_includes File.read(File.join(project.directory, "junit.xml")), %(<testsuites name="quickdraw" tests="2" failures="1" errors="1")
	end

	test "quotes paths in rerun commands", timeout: 20 do
		result = project("has space.test.rb" => "class A < Quickdraw::Test; test('a') { assert false }; end\n").run("-p", "1", "--no-history", "--format", "agent")

		assert_match result.output, /Rerun: (bundle exec )?quickdraw 'has space\.test\.rb:1'$/
	end

	test "counts a file that failed to load in JUnit totals", timeout: 20 do
		project = project(
			"broken.test.rb" => "raise 'broken'\n",
			"fine.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n",
		)

		project.run("-p", "1", "--no-history", "--format", "junit:junit.xml")
		xml = File.read(File.join(project.directory, "junit.xml"))

		assert_includes xml, %(<testsuites name="quickdraw" tests="2" failures="0" errors="1")
		assert_includes xml, %(<testcase name="broken.test.rb could not be loaded")
	end

	test "annotates problems and writes a job summary under GitHub Actions", timeout: 20 do
		project = shapes
		summary = File.join(project.directory, "summary.md")
		result = project.run("-p", "1", "--no-history", env: { "GITHUB_ACTIONS" => "true", "GITHUB_STEP_SUMMARY" => summary })

		assert_includes result.output, "::error file=shapes.test.rb,line=5,title=Shapes › computes area::Expected  7%0AActual    6"
		assert_includes result.output, "::error file=shapes.test.rb,line=2,title=Shapes › raises in a helper::NoMethodError"
		assert_includes File.read(summary), "| 3 | 1 | 1 | 0 | 0 | 1 | 0 |"
	end

	test "writes JUnit XML", timeout: 20 do
		project = shapes
		path = File.join(project.directory, "junit.xml")
		project.run("-p", "1", "--no-history", "--format", "junit:junit.xml")
		xml = File.read(path)

		assert_includes xml, %(<testsuites name="quickdraw" tests="3" failures="1" errors="1")
		assert_includes xml, %(<testcase name="passes" classname="Shapes" file="shapes.test.rb" line="12")
		assert_includes xml, %(<failure message="Expected 7 Actual 6">)
		assert_includes xml, %(<error type="NoMethodError")
	end
end
