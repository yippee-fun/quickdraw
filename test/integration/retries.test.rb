# frozen_string_literal: true

require_relative "../support/integration"
require "json"

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

	# Fails in every process it has run in before, so it passes only in a fresh one.
	FIRST_WORKER_FAILS = {
		"once.test.rb" => <<~RUBY,
			class Once < Quickdraw::Test
				test("fails in its first worker") do
					pids = File.exist?("runs") ? File.readlines("runs").map { |line| line.split.first } : []
					File.write("runs", "\#{Process.pid} \#{$other_loaded.inspect}\\n", mode: "a")
					assert pids.any? && !pids.include?(Process.pid.to_s)
				end
			end
		RUBY
		"other.test.rb" => FIRST_RUN_FAILS.fetch("other.test.rb"),
	}.freeze

	def setup
		super
		skip "Retries need fork" unless Process.respond_to?(:fork)
	end

	def runs(project) = File.readlines(File.join(project.directory, "runs"), chomp: true).map(&:split)

	test "a test that passes when run again in the same worker is flaky on its own, and fails the run", timeout: 20 do
		project = project(FIRST_RUN_FAILS)
		result = project.run("-p", "1", "--no-history", "--format", "human")

		refute result.success?
		match { result => { summary: /\A2 tests · 2 assertions · 1 flaky · / } }
		assert_includes result.output, "~ once.test.rb:2 Once › fails the first time"
		assert_includes result.output, "Passed when run again in the same worker, so it fails some of the time on its own."
		refute_includes result.output, "bisect"
		assert_equal runs(project).map(&:first).uniq.size, 1
	end

	test "a test that fails again in the same worker, then passes in a fresh one, likely depends on tests before it", timeout: 20 do
		project = project(FIRST_WORKER_FAILS)
		result = project.run("-p", "1", "--no-history", "--format", "human")

		refute result.success?
		assert_includes result.output, "Failed again in the same worker, then passed in a fresh one, so it likely depends on tests that ran before it."
		# Bisect reads history, which this run doesn't record.
		refute_includes result.output, "bisect"

		first, again, fresh = runs(project)
		assert_equal first[0], again[0]
		refute_equal fresh[0], first[0]
		assert_equal fresh[1], "nil"
	end

	test "--allow-flaky passes the run, and JSON shows the test as flaky", timeout: 20 do
		project = project(FIRST_RUN_FAILS)
		result = project.run("-p", "1", "--no-history", "--allow-flaky", "--format", "json")

		require "json"

		assert(result.success?) { result.output }
		events = result.stdout.lines.map { |line| JSON.parse(line, symbolize_names: true) }
		match { events.find { |event| event[:name]&.include?("fails the first time") } => { status: "flaky", passed_on_retry: 1, flake: "nondeterministic", attempts: [{ in: "first run", status: "failed" }, { in: "same worker", status: "passed" }] } }
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
		assert_equal File.readlines(File.join(project.directory, "runs")).size, 4

		project.run("-p", "1", "--no-history", "--retry", "0")
		assert_equal File.readlines(File.join(project.directory, "runs")).size, 5
	end

	test "stops retrying once ten tests have failed", timeout: 20 do
		project = project("many.test.rb" => <<~RUBY)
			class Many < Quickdraw::Test
				12.times { |i| test("fails \#{i}") { File.write("runs", "run\\n", mode: "a"); assert false } }
			end
		RUBY

		result = project.run("-p", "2", "--no-history")

		match { result => { summary: /\A12 tests · 12 assertions · 12 failed · / } }
		# The first ten, again in the same worker, then in a fresh one.
		assert_equal File.readlines(File.join(project.directory, "runs")).size, 32
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

	test "history lists a test that passed on retry as flaky, and suggests bisecting one that depends on others", timeout: 30 do
		project = project(FIRST_WORKER_FAILS)
		assert_includes project.run("-p", "1", "--format", "human").output, "⌕ quickdraw bisect once.test.rb:2"

		flaky = project.run("history").output[/^Flaky tests.*\z/m]
		assert_includes flaky, "fails in its first worker  Once · once.test.rb:2"
	end

	test "passes each flaky test to config's on_flaky callbacks, in the loader, once, and shows one that raises", timeout: 20 do
		project = project(
			**FIRST_RUN_FAILS,
			"config/quickdraw.rb" => <<~RUBY,
				$loader = Process.pid

				Quickdraw.configure do |config|
					config.on_flaky { |flake| raise "unreachable" }
					config.on_flaky do |flake|
						File.write("reported", [flake.name, flake.kind, flake.attempts.map { |attempt| attempt[:in] }, flake.rerun, Process.pid == $loader].inspect + "\\n", mode: "a")
					end
				end
			RUBY
		)

		result = project.run("-p", "2", "--no-history", "--seed", "4")

		assert_includes result.stderr, "config.on_flaky raised RuntimeError: unreachable, reporting once.test.rb:2"
		assert_equal File.readlines(File.join(project.directory, "reported"), chomp: true), [
			["Once › fails the first time", :nondeterministic, ["first run", "same worker"], "quickdraw --seed 4 once.test.rb:2", true].inspect,
		]
	end

	test "a flake's key tells tests with the same name apart, and its JSON survives a message that isn't UTF-8", timeout: 20 do
		project = project("twice.test.rb" => <<~RUBY)
			class Twice < Quickdraw::Test
				2.times do |i|
					test("same name") do
						File.write("runs\#{i}", "run\\n", mode: "a")
						raise "bad \\xFF byte".b if File.readlines("runs\#{i}").size == 1
						assert true
					end
				end
			end
		RUBY

		project.run("-p", "1", "--no-history", "--seed", "1", "--flakes", "flakes.json")
		flakes = JSON.parse(File.read(File.join(project.directory, "flakes.json"), encoding: "UTF-8"), symbolize_names: true)[:flakes]

		assert_equal flakes.size, 2
		assert_equal flakes.map { |flake| flake[:key] }.uniq.size, 2
		assert_includes flakes.first[:attempts].first[:errors].first[:message], "bad � byte"
	end

	test "--flakes can't be used with --watch", timeout: 20 do
		match { project(FIRST_RUN_FAILS).run("--watch", "--flakes", "flakes.json") => { exit_status: 2, stderr: /--flakes is for a single run/ } }
	end

	test "--flakes writes the run's flakes as JSON, with each attempt, and an empty list without any", timeout: 20 do
		project = project(FIRST_WORKER_FAILS)
		result = project.run("-p", "1", "--no-history", "--seed", "4", "--flakes", "tmp/flakes.json", env: { "GITHUB_REPOSITORY" => "acme/shop", "GITHUB_RUN_ID" => "7", "GITHUB_SHA" => "abc123", "GITHUB_REF_NAME" => "main" })

		refute result.success?
		report = JSON.parse(File.read(File.join(project.directory, "tmp/flakes.json"), encoding: "UTF-8"), symbolize_names: true)
		match do
			report => {
				seed: 4, commit: "abc123", branch: "main", ci_url: "https://github.com/acme/shop/actions/runs/7",
				flakes: [{
					key: /\A\h{12}\z/, path: "once.test.rb", line: 2, name: "Once › fails in its first worker", kind: "order_dependent", rerun: "quickdraw --seed 4 once.test.rb:2",
					attempts: [{ in: "first run", status: "failed", failures: [{ message: String }] }, { in: "same worker", status: "failed" }, { in: "fresh worker", status: "passed" }],
				}],
			}
		end

		project.write("once.test.rb" => "class Once < Quickdraw::Test; test('passes') { assert true }; end\n")
		project.run("-p", "1", "--no-history", "--flakes", "tmp/flakes.json")
		match { JSON.parse(File.read(File.join(project.directory, "tmp/flakes.json")), symbolize_names: true) => { flakes: [] } }
	end
end
