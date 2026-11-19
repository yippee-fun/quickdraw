# frozen_string_literal: true

require_relative "../support/integration"

class RetriesTest < Quickdraw::Test
	include Integration

	# Fails the first time it runs, records each run's process and whether the
	# other file was loaded in it, then passes.
	FIRST_RUN_FAILS = {
		"once.test.rb" => <<~RUBY,
			class Once < Quickdraw::Test
				test("fails the first time") do
					File.write("runs", "\#{Process.pid} \#{$other_loaded.inspect}\\n", mode: "a")
					assert File.readlines("runs").size > 1
				end
			end
		RUBY
		"other.test.rb" => "$other_loaded = true\nclass Other < Quickdraw::Test; test('passes') { assert true }; end\n",
	}.freeze

	def setup
		super
		skip "Retries need fork" unless Process.respond_to?(:fork)
	end

	test "a test that passes on retry, in a fresh worker, is flaky and fails the run", timeout: 20 do
		project = project(FIRST_RUN_FAILS)
		result = project.run("-p", "1", "--no-history", "--format", "human")

		refute result.success?
		match { result => { summary: /\A2 tests · 2 assertions · 1 flaky · / } }
		assert_includes result.output, "~ once.test.rb:2 Once › fails the first time"
		assert_includes result.output, "Passed when retried in a fresh worker, so it’s flaky or depends on tests that ran before it."
		# Bisect reads history, which this run doesn't record.
		refute_includes result.output, "bisect"

		runs = File.readlines(File.join(project.directory, "runs"), chomp: true).map(&:split)
		assert_equal runs.size, 2
		refute_equal runs[0][0], runs[1][0]
		assert_equal runs[1][1], "nil"
	end

	test "--allow-flaky passes the run, and JSON shows the test as flaky", timeout: 20 do
		project = project(FIRST_RUN_FAILS)
		result = project.run("-p", "1", "--no-history", "--allow-flaky", "--format", "json")

		require "json"

		assert(result.success?) { result.output }
		events = result.stdout.lines.map { |line| JSON.parse(line, symbolize_names: true) }
		match { events.find { |event| event[:name]&.include?("fails the first time") } => { status: "flaky", passed_on_retry: 1 } }
		match { events.last => { event: "finish", passed: true, flaky: 1, failed: 0 } }
	end

	test "a test that fails every time is retried, then reported as failed", timeout: 20 do
		project = project("always.test.rb" => <<~RUBY)
			class Always < Quickdraw::Test
				test("fails") { File.write("runs", "run\\n", mode: "a"); assert false }
			end
		RUBY

		result = project.run("-p", "1", "--no-history", "--retry", "2", "--format", "human")

		refute result.success?
		match { result => { summary: /\A1 test · 1 assertion · 1 failed · / } }
		refute_includes result.output, "flaky"
		assert_equal File.readlines(File.join(project.directory, "runs")).size, 3

		project.run("-p", "1", "--no-history", "--retry", "0")
		assert_equal File.readlines(File.join(project.directory, "runs")).size, 4
	end

	test "stops retrying once ten tests have failed", timeout: 20 do
		project = project("many.test.rb" => <<~RUBY)
			class Many < Quickdraw::Test
				12.times { |i| test("fails \#{i}") { File.write("runs", "run\\n", mode: "a"); assert false } }
			end
		RUBY

		result = project.run("-p", "2", "--no-history")

		match { result => { summary: /\A12 tests · 12 assertions · 12 failed · / } }
		assert_equal File.readlines(File.join(project.directory, "runs")).size, 22
	end

	test "a test that fails, then skips when retried, isn't flaky", timeout: 20 do
		project = project("skips.test.rb" => <<~RUBY)
			class Skips < Quickdraw::Test
				test("skips the second time") do
					skip "second run" if File.exist?("ran")
					File.write("ran", "")
					assert false
				end
			end
		RUBY

		result = project.run("-p", "1", "--no-history", "--allow-flaky")

		refute result.success?
		match { result => { summary: /\A1 test · 1 assertion · 1 failed · / } }
	end

	test "history lists a test that passed on retry as flaky, and suggests bisecting it", timeout: 30 do
		project = project(FIRST_RUN_FAILS)
		assert_includes project.run("-p", "1", "--format", "human").output, "⌕ quickdraw bisect once.test.rb:2"

		flaky = project.run("history").output[/^Flaky tests.*\z/m]
		assert_includes flaky, "once.test.rb:2 Once › fails the first time"
	end
end
