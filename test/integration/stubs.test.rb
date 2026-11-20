# frozen_string_literal: true

require_relative "../support/integration"

class StubsIntegrationTest < Quickdraw::Test
	include Integration

	test "undoes a test's stubs before the next test in its worker, however it ends, without leaking", timeout: 20 do
		result = project("stubbed.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--leaks", "fail", "--format", "human")
			module Clock
				def self.now = :real
			end

			class Stubbed < Quickdraw::Test
				def stub_everything
					assert_equal Clock.now, :real
					refute ENV.key?("STUBBED")
					refute Object.const_defined?(:STUBBED)

					stub(Clock, :now, returns: :stubbed)
					stub_env("STUBBED" => "1")
					stub_const("STUBBED", 1)

					threads = spy(Thread, :new)
					Thread.new { 1 }.join
					assert_equal threads.count, 1

					stub(Thread, :new, returns: nil)
					assert_nil Thread.new { 1 }
				end

				test("passes") { stub_everything }
				test("fails") { stub_everything; assert false }
				test("raises") { stub_everything; raise "boom" }
				test("skips") { stub_everything; skip }
			end
		RUBY

		match { result => { summary: /\A4 tests · 21 assertions · 1 failed · 1 skipped · 1 errored/ } }
		assert_includes result.stdout, "RuntimeError: boom"
		refute_includes result.output, "Quickdraw::Leak"
		refute_includes result.output, "left state behind"
	end
end
