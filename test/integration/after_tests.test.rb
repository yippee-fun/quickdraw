# frozen_string_literal: true

require_relative "../support/integration"

class AfterTestsTest < Quickdraw::Test
	include Integration

	# Each test gathers its number and records the process it ran in, slowly
	# enough that they spread across workers.
	def numbers(check: "assert_equal gathered, [1, 2, 3, 4, 5, 6]", third: "assert true")
		project("numbers.test.rb" => <<~RUBY)
			class Numbers < Quickdraw::Test
				def number(n)
					sleep 0.05
					File.write("pids", "\#{Process.pid}\\n", mode: "a")
					gather n
				end

				test("one") { number 1; assert true }
				test("two") { number 2; assert true }
				test("three") { number 3; #{third} }

				describe "more" do
					test("four") { number 4; assert true }
					test("five") { number 5; assert true }
					test("six") { number 6; assert true }
				end

				after_tests "checks them all" do |gathered|
					#{check}
				end
			end

			class MoreNumbers < Numbers
				test("seven") { number 7; assert true }
			end
		RUBY
	end

	def events(result) = result.events.select { |event| event["event"] == "test" }
	def check_event(result) = events(result).find { |event| event["name"] == "Numbers › checks them all" }

	test "runs once every test of its class and describe groups has passed, given what they gathered in order", timeout: 30 do
		project = numbers
		result = project.run("-p", "3", "--no-history", "--format", "json")

		assert(result.success?) { result.output }
		assert_equal events(result).size, 8
		assert_equal check_event(result).slice("status", "assertions"), { "status" => "passed", "assertions" => 1 }
		# Without fork, there's one worker.
		assert File.readlines(File.join(project.directory, "pids")).uniq.size > 1 if Process.respond_to?(:fork)
	end

	test "fails the run when its check fails", timeout: 30 do
		result = numbers(check: "assert_equal gathered, []").run("-p", "3", "--no-history", "--format", "json")

		refute result.success?
		assert_equal check_event(result)["status"], "failed"
	end

	test "is skipped when a test it follows fails", timeout: 30 do
		result = numbers(third: "assert false").run("-p", "3", "--no-history", "--format", "json")

		refute result.success?
		assert_equal check_event(result).slice("status", "skip_reason"), { "status" => "skipped", "skip_reason" => "Not every test it runs after passed." }
	end

	test "is given what a test that passed on retry gathered then", timeout: 30 do
		skip "Retries need fork" unless Process.respond_to?(:fork)

		third = 'retried = File.exist?("failed"); File.write("failed", ""); gather(retried ? :retry : :first); assert retried'
		result = numbers(check: "assert_equal gathered, [1, 2, 3, :retry, 4, 5, 6]", third:).run("-p", "3", "--no-history", "--allow-flaky", "--format", "json")

		assert(result.success?) { result.output }
		assert_equal check_event(result)["status"], "passed"
	end

	test "selecting it selects the tests it follows", timeout: 30 do
		project = numbers
		line = File.readlines(File.join(project.directory, "numbers.test.rb")).index { |source| source.include?("after_tests") } + 1
		result = project.run("-p", "2", "--no-history", "--format", "json", "numbers.test.rb:#{line}")

		assert(result.success?) { result.output }
		assert_equal events(result).size, 7
	end

	test "isn't selected without every test it follows", timeout: 30 do
		project = numbers

		match { project.run("-p", "2", "--no-history", "numbers.test.rb:10") => { summary: /\A1 test · / } }
		match { project.run("-p", "2", "--no-history", "-x", "five") => { summary: /\A6 tests · / } }
		match { project.run("-p", "2", "--no-history", "-n", "checks them all", "-x", "five") => { summary: /\A0 tests · / } }
	end

	test "defined by a helper elsewhere, it's at the line that called the helper", timeout: 30 do
		project = project(
			"config/quickdraw.rb" => <<~RUBY,
				module Checks
					def checks_numbers
						after_tests("checks the numbers") { |gathered| assert_equal gathered, [1] }
					end
				end
			RUBY
			"numbers.test.rb" => <<~RUBY,
				class Numbers < Quickdraw::Test
					extend Checks

					test("one") { gather 1; assert true }

					checks_numbers
				end
			RUBY
		)
		result = project.run("-p", "1", "--no-history", "--format", "json", "numbers.test.rb:6")

		assert(result.success?) { result.output }
		assert_equal events(result).map { |event| [event["name"], event["line"]] }, [["Numbers › one", 4], ["Numbers › checks the numbers", 6]]
	end

	test "gathers only plain data" do
		project = project("objects.test.rb" => <<~RUBY)
			class Objects < Quickdraw::Test
				test("gathers an object") { gather Object.new }
			end
		RUBY
		result = project.run("-p", "1", "--no-history")

		refute result.success?
		assert_includes result.output, "Expected plain data (nil, true, false, numbers, strings, symbols, and arrays and hashes of them), not Object."
	end
end
