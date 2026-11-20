# frozen_string_literal: true

require_relative "../support/integration"

class IntegrationHelpersTest < Quickdraw::Test
	include Integration

	test "screen keeps each line as the status line's redraws left it" do
		output = [
			"\e[?25l",
			"\r\e[K\e[36m⠋\e[0m Booting\e[2m · \e[0m\e[2m0.1s\e[0m\r",
			"\r\e[K\e[36m⠙\e[0m 0/2 files · 0 tests · 0.2s\r",
			"\r\e[K✓ a.test.rb  1 test\r\n",
			"\r\e[K⠹ 1/2 files · 1 test · 0.3s\r",
			"\r\e[K⠸ 1/2 files · 1 test · 0.4s\r",
		].join

		assert_equal Integration.screen(output), "✓ a.test.rb  1 test\n⠸ 1/2 files · 1 test · 0.4s"
		assert_equal Integration.screen("\r\e[K⠸ 1/2 files\r\r\e[K\e[?25hPASSED\n"), "PASSED\n"
		assert_equal Integration.screen("abcdef\rxy\nnext"), "xycdef\nnext"
		assert_equal Integration.screen("Watching\n\e[H\e[2JChanged a.rb\n"), "Watching\nChanged a.rb\n"
	end

	test "shows the output so far of a run that didn't finish, as a terminal would, indented", timeout: 20 do
		skip "This Ruby has no PTY" unless terminal?
		skip "The status line needs fork, to capture what tests print" unless Process.respond_to?(:fork)

		project = project("a.test.rb" => "class A < Quickdraw::Test; test('hangs') { sleep 30 }; end\n")
		error = assert_raises(RuntimeError) { project.run("-p", "1", env: { "TERM" => "xterm" }, tty: [20, 80], timeout: 3) }

		assert_match error.message, %r{\AQuickdraw didn’t finish within 3s\. Output so far:\n  \S (?:Booting|0/1 files · 0 tests) · \d+\.\ds\z}
	end
end
