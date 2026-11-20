# frozen_string_literal: true

require_relative "../support/integration"

class NoAssertionsTest < Quickdraw::Test
	include Integration

	MESSAGE = "This test made no assertions. A test without a block is pending, if it isn’t written yet."

	test "fails a test that makes no assertions, at its line, even when retried", timeout: 20 do
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--format", "human")
			class A < Quickdraw::Test
				test("adds") { 1 + 1 }
				test("raises") { raise "broken" }
			end
		RUBY

		refute result.success?
		assert_includes result.output, "✗ a.test.rb:2 A › adds"
		assert_includes result.output, MESSAGE
		assert_equal result.output.scan(MESSAGE).size, 1
		match { result => { summary: /\A2 tests · 0 assertions · 1 failed · 1 errored · / } }
	end

	test "leaves pending and skipped tests alone", timeout: 20 do
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--format", "human")
			class A < Quickdraw::Test
				test "to write later"
				test("skips") { skip "needs a network" }
			end
		RUBY

		assert result.success?
		match { result => { summary: /\A2 tests · 0 assertions · 1 skipped · 1 pending · / } }
	end

	test "counts properties, fuzz tests and assertions made in threads", timeout: 20 do
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--format", "human")
			class A < Quickdraw::Test
				test("checks a property") { check(integer) { |n| assert_equal n + 0, n } }
				fuzz("fuzzes", integer) { |n| assert_equal n * 1, n }
				test("asserts in a thread") { Thread.new { assert true }.join }
			end
		RUBY

		assert result.success?
		match { result => { summary: /\A3 tests · 3 assertions · / } }
	end

	test "reports the test as failed in JSON", timeout: 20 do
		result = project("a.test.rb" => "class A < Quickdraw::Test\n\ttest('adds') { 1 + 1 }\nend\n").run("-p", "1", "--no-history", "--format", "json")

		refute result.success?

		test_event = result.events.find { |event| event["event"] == "test" }

		assert_equal test_event.slice("status", "assertions", "failures"), {
			"status" => "failed",
			"assertions" => 0,
			"failures" => [{ "message" => MESSAGE, "path" => "a.test.rb", "line" => 2 }],
		}
		assert_equal result.events.last.slice("event", "failed"), { "event" => "finish", "failed" => 1 }
	end
end
