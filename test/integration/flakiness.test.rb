# frozen_string_literal: true

require_relative "../support/integration"

class FlakinessTest < Quickdraw::Test
	include Integration

	def setup
		super
		skip "flaky and bisect need fork" unless Process.respond_to?(:fork)
	end

	POLLUTED = {
		"polluter.test.rb" => <<~RUBY,
			class Polluter < Quickdraw::Test
				test("harmless") { assert true }
				test("sets a global") { $polluted = true; assert true }
				test("also harmless") { assert true }
			end
		RUBY
		"victim.test.rb" => <<~RUBY,
			class Victim < Quickdraw::Test
				test("expects a clean global") { refute $polluted }
			end
		RUBY
		"other.test.rb" => <<~RUBY,
			class Other < Quickdraw::Test
				test("one") { assert true }
				test("two") { assert true }
			end
		RUBY
	}.freeze

	test "flaky lists tests that pass in some runs and fail in others", timeout: 30 do
		result = project(
			"alternates.test.rb" => <<~RUBY,
				class Alternates < Quickdraw::Test
					test("fails every other run") do
						runs = File.exist?("runs") ? File.read("runs").to_i : 0
						File.write("runs", runs + 1)
						assert runs.even?
					end
				end
			RUBY
			"steady.test.rb" => "class Steady < Quickdraw::Test; test('passes') { assert true }; end\n",
		).run("flaky", "--runs", "4", "-p", "1")

		assert_equal result.status.exitstatus, 1
		assert_equal result.stdout.scan(/^  ([✓✗]) run \d of 4  seed \d+$/).flatten, ["✓", "✗", "✓", "✗"]
		assert_includes result.stdout, "FLAKY fails every other run  Alternates · alternates.test.rb:2\n      failed 2 of 4 runs · seeds "
		assert_includes result.stdout, "⌕ quickdraw bisect alternates.test.rb:2"
		assert_includes result.stdout, "\n\nFAILED 1 flaky test in 4 runs\n"
		refute_includes result.stdout, "Steady"
	end

	test "flaky says when nothing was flaky", timeout: 30 do
		result = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n").run("flaky", "--runs", "2", "-p", "1")

		assert result.success?
		assert_includes result.stdout, "PASSED No flaky tests in 2 runs\n"
	end

	test "flaky explains bad arguments", timeout: 20 do
		match { project.run("flaky", "--runs", "none") => { stderr: /--runs needs a number of runs/ } }
		match { project.run("flaky", "--no-history") => { stderr: /can’t be used with --no-history/ } }
		match { project.run("flaky", "--nmae", "x") => { stderr: /Did you mean --name\?/, exit_status: 2 } }
		match { project.run("flaky", "--failed") => { stderr: /can’t be used with --failed/, exit_status: 2 } }
		match { project.run("flaky", "-w") => { stderr: /can’t be used with --watch/, exit_status: 2 } }
	end

	test "flaky passes paths after -- as they are", timeout: 30 do
		result = project("-a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n").run("flaky", "--runs", "1", "-p", "1", "--", "-a.test.rb")

		assert(result.success?) { result.output }
	end

	test "bisect says when the failing test can't be found any more", timeout: 60 do
		project = project(POLLUTED)
		seed = (1..30).find { |it| !project.run("-p", "1", "--no-history", "--seed", it.to_s).success? }
		project.run("-p", "1", "--seed", seed.to_s)
		project.write("victim.test.rb" => POLLUTED["victim.test.rb"].sub("expects a clean global", "renamed"))

		result = project.run("bisect", "victim.test.rb:2")

		assert_equal result.exit_status, 1
		assert_includes result.stdout, "Couldn’t find victim.test.rb:2 Victim › expects a clean global to replay it."
	end

	test "bisect finds the test that a failure depends on", timeout: 60 do
		project = project(POLLUTED)

		# A seed gives the same order every time without history, so some seed puts
		# the polluter first. History orders files slowest first, so the failing
		# seed is found without it, then recorded.
		seed = (1..30).find { |it| !project.run("-p", "1", "--no-history", "--seed", it.to_s).success? }
		refute project.run("-p", "1", "--seed", seed.to_s).success?

		result = project.run("bisect", "victim.test.rb:2")

		assert result.success?
		assert_includes result.stdout, "FOUND It fails after this test:\n      ✗ sets a global  Polluter · polluter.test.rb:3\n"
	end

	test "bisect finds every test a failure needs, when it needs more than one", timeout: 60 do
		project = project(
			"setup.test.rb" => <<~RUBY,
				class Setup < Quickdraw::Test
					test("sets a") { $a = true; assert true }
					test("harmless 1") { assert true }
					test("harmless 2") { assert true }
					test("harmless 3") { assert true }
					test("harmless 4") { assert true }
					test("harmless 5") { assert true }
					test("sets b") { $b = true; assert true }
				end
			RUBY
			"victim.test.rb" => <<~RUBY,
				class Victim < Quickdraw::Test
					test("fails when both are set") { refute $a && $b }
				end
			RUBY
		)
		seed = (1..200).find { |it| !project.run("-p", "1", "--no-history", "--seed", it.to_s).success? }
		refute project.run("-p", "1", "--seed", seed.to_s).success?

		result = project.run("bisect", "victim.test.rb:2")

		assert(result.success?) { result.output }
		assert_includes result.stdout, "FOUND It fails after these tests, together:\n"
		found = result.stdout.scan(/✗ (.+?)  Setup/).flatten
		assert_equal found.sort, ["sets a", "sets b"]
	end

	test "bisect explains a failure that doesn't depend on order", timeout: 30 do
		project = project("a.test.rb" => <<~RUBY)
			class A < Quickdraw::Test
				test("passes") { assert true }
				test("fails") { assert false }
			end
		RUBY
		project.run("-p", "1")

		result = project.run("bisect", "a.test.rb:3")

		assert_equal result.status.exitstatus, 1
		assert_includes result.stdout, "It fails on its own too"
	end

	test "bisect needs a test that has failed", timeout: 30 do
		project = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n")

		match { project.run("bisect", "a.test.rb:1") => { stderr: /no run history yet/ } }
		project.run("-p", "1")
		match { project.run("bisect", "a.test.rb:1") => { stderr: /a\.test\.rb:1 hasn’t failed in the run history/ } }
		match { project.run("bisect", "a.test.rb") => { stderr: /Usage: .*bisect PATH:LINE/, exit_status: 2 } }
	end
end
