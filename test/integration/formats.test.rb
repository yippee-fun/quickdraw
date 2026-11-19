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

	test "uses the agent format under an AI coding agent", timeout: 20 do
		result = shapes.run("-p", "1", "--no-history", env: { "CLAUDECODE" => "1" })

		refute result.success?
		assert_includes result.output, "FAILED shapes.test.rb:4 Shapes › computes area"
		assert_includes result.output, "shapes.test.rb:5: assert_equal area(2, 3), 7"
		assert_includes result.output, "ERROR shapes.test.rb:8 Shapes › raises in a helper"
		assert_includes result.output, "shapes.test.rb:2: def area(width, height) = width * height"
		assert_match result.output, /Rerun: (bundle exec )?quickdraw shapes\.test\.rb:4$/
		assert_match result.output, /^FAILED: 3 tests, 1 passed, 1 failed, 1 errored in [\d.]+s \(seed \d+\)$/
		refute_includes result.output, "\e["
	end

	test "keeps the agent format to one line when everything passes", timeout: 20 do
		result = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n").run("-p", "1", "--no-history", "--format", "agent")

		assert result.success?
		assert_match result.stdout, /\APASSED: 1 test, 1 passed in [\d.]+s \(seed \d+\)\n\z/
	end

	test "shows the first problems in full and the rest one line each, for agents", timeout: 20 do
		result = project("many.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--format", "agent")
			class Many < Quickdraw::Test
				15.times { |i| test("fails \#{i}") { assert false } }
			end
		RUBY

		assert_equal result.output.scan(/^FAILED many\.test\.rb/).size, 10
		assert_includes result.output, "5 more problems:"
		assert_equal result.output.scan(/^- FAILED many\.test\.rb:\d+ Many › fails \d+$/).size, 5
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
		result = project("noisy.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--format", "json")
			class Noisy < Quickdraw::Test
				test("prints") { puts "debugging"; system("echo", "from a subprocess"); assert true }
			end
		RUBY

		result.stdout.lines.each { |line| JSON.parse(line) }
		assert_includes result.stderr, "debugging"
		assert_includes result.stderr, "from a subprocess"
	end

	test "reports invalid UTF-8 and binary messages without crashing", timeout: 20 do
		require "json"
		project = project("binary.test.rb" => <<~RUBY)
			class Binary < Quickdraw::Test
				test("raises binary") { raise "\\xff".b }
				test("fails with invalid UTF-8") { assert(false) { "bad \\xff".dup.force_encoding("UTF-8") } }
			end
		RUBY

		json = project.run("-p", "1", "--no-history", "--format", "json", "--junit", "junit.xml")
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

		project.run("-p", "1", "--no-history", "--junit", "junit.xml")
		xml = File.read(File.join(project.directory, "junit.xml"))

		assert_includes xml, %(<testsuites name="quickdraw" tests="2" failures="0" errors="1")
		assert_includes xml, %(<testcase name="broken.test.rb could not be loaded")
	end

	test "annotates problems and writes a job summary under GitHub Actions", timeout: 20 do
		project = shapes
		summary = File.join(project.directory, "summary.md")
		result = project.run("-p", "1", "--no-history", env: { "GITHUB_ACTIONS" => "true", "GITHUB_STEP_SUMMARY" => summary })

		assert_includes result.output, "::error file=shapes.test.rb,line=5,title=Shapes › computes area::Actual:%0A"
		assert_includes result.output, "::error file=shapes.test.rb,line=2,title=Shapes › raises in a helper::NoMethodError"
		assert_includes File.read(summary), "| 3 | 1 | 1 | 1 | 0 |"
	end

	test "writes JUnit XML", timeout: 20 do
		project = shapes
		path = File.join(project.directory, "junit.xml")
		project.run("-p", "1", "--no-history", "--junit", "junit.xml")
		xml = File.read(path)

		assert_includes xml, %(<testsuites name="quickdraw" tests="3" failures="1" errors="1")
		assert_includes xml, %(<testcase name="passes" classname="Shapes" file="shapes.test.rb" line="12")
		assert_includes xml, %(<failure message="Actual: 6 Expected: 7">)
		assert_includes xml, %(<error type="NoMethodError")
	end
end
