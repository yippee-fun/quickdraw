# frozen_string_literal: true

require_relative "../support/integration"

class AroundTestIntegrationTest < Quickdraw::Test
	include Integration

	def run_with(callback, test_source = "class T < Quickdraw::Test; test('a') { puts 'ran'; assert true }; end\n")
		project(
			"config/quickdraw.rb" => "Quickdraw.configure { |config| config.around_test #{callback} }\n",
			"t.test.rb" => test_source,
		).run("-p", "1", "--no-history", "--no-capture", "--retry", "0", "--format", "human")
	end

	test "wraps setup and teardown, and sees the test's exceptions", timeout: 20 do
		result = run_with("do |test, run| puts 'before'; run.call; rescue => error; puts \"saw \#{error.message}\"; raise; end", <<~RUBY)
			class T < Quickdraw::Test
				def setup = puts("setup")
				def teardown = puts("teardown")
				test("a") { raise "boom" }
			end
		RUBY

		refute result.success?
		assert_equal result.stdout.scan(/^(?:before|setup|teardown|saw boom)$/), ["before", "setup", "teardown", "saw boom"]
	end

	test "a callback can skip the test", timeout: 20 do
		result = run_with("{ |test, _run| test.skip('no network') }")

		assert result.success?
		refute_includes result.stdout, "ran"
		match { result => { summary: /1 skipped/ } }
	end

	test "a callback can run the test again without repeating deferred blocks", timeout: 20 do
		result = run_with("{ |_test, run| 2.times { run.call } }", <<~RUBY)
			class T < Quickdraw::Test
				test("a") { defer { puts "deferred" }; assert true }
			end
		RUBY

		assert result.success?
		assert_equal result.stdout.scan(/^deferred$/).size, 2
	end

	test "a callback that doesn't call run makes the test an error, not a pass", timeout: 20 do
		result = run_with("{ |_test, _run| nil }")

		refute result.success?
		refute_includes result.stdout, "ran"
		assert_includes result.output, "An around_test callback in config didn’t call run, so the test didn’t run."
	end
end
