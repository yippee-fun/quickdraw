# frozen_string_literal: true

require_relative "../support/integration"

class LeaksTest < Quickdraw::Test
	include Integration

	LEAKY = <<~RUBY
		class Leaky < Quickdraw::Test
			test("starts a thread") { Thread.new { sleep }; assert true }
			test("joins its thread") { Thread.new { 1 }.join; assert true }
			test("starts a process") { spawn("sleep 5"); assert true }
			test("sets ENV") { ENV["LEAKY_TOKEN"] = "secret"; assert true }
			test("restores ENV") { ENV["TIDY"] = "1"; ENV.delete("TIDY"); assert true }
		end
	RUBY

	def leaky = project("leaky.test.rb" => LEAKY)

	test "warns about threads, child processes and ENV changes a test leaves behind", timeout: 20 do
		result = leaky.run("-p", "1", "--no-history", "--format", "human")

		assert result.success?
		assert_includes result.stdout, "! 3 tests left state behind, which can make later tests fail\n"
		assert_includes result.stdout, "  leaky.test.rb:2 Leaky › starts a thread\n    A thread started at leaky.test.rb:2 is still running.\n"
		assert_match result.stdout, /  leaky\.test\.rb:4 Leaky › starts a process\n    Child process \d+ \(sleep\) is still running\.\n/
		assert_includes result.stdout, "  leaky.test.rb:5 Leaky › sets ENV\n    ENV wasn't restored: added LEAKY_TOKEN.\n"
		refute_includes result.output, "secret"
		refute_includes result.output, "joins its thread"
		refute_includes result.output, "TIDY"
	end

	test "reports a child process that exited without being waited for", timeout: 20 do
		result = project("zombie.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--format", "agent")
			class Zombie < Quickdraw::Test
				test("forks") { fork { exit!(4) }; sleep 0.2; assert true }
				test("waits") { Process.wait(fork { exit!(0) }); assert true }
			end
		RUBY

		assert_match result.stdout, /^- zombie\.test\.rb:2 Zombie › forks: Child process \d+ exited \(status 4\), but wasn't waited for\.$/
		refute_includes result.stdout, "Zombie › waits"
	end

	test "leaves processes config started alone", timeout: 20 do
		result = project(
			"config/quickdraw.rb" => "Quickdraw.configure { |config| config.after_forking { $pid = spawn('true') } }\n",
			"a.test.rb" => <<~RUBY,
				class A < Quickdraw::Test
					test("waits for config's process") { sleep 0.1; assert Process.wait($pid) }
					test("passes") { assert true }
				end
			RUBY
		).run("-p", "1", "--no-history", "--format", "human")

		assert result.success?
		refute_includes result.output, "left state behind"
	end

	test "--leaks fail makes a leak an error", timeout: 20 do
		result = leaky.run("-p", "1", "--no-history", "--leaks", "fail", "--format", "human")

		refute result.success?
		assert_includes result.stdout, "Quickdraw::Leak: A thread started at leaky.test.rb:2 is still running."
		match { result => { summary: /\A5 tests · 5 assertions · 3 errored/ } }
	end

	test "--leaks off doesn't check", timeout: 20 do
		result = leaky.run("-p", "1", "--no-history", "--leaks", "off", "--format", "human")

		assert result.success?
		refute_includes result.output, "left state behind"
	end

	test "lists leaks in JSON events", timeout: 20 do
		require "json"
		result = leaky.run("-p", "1", "--no-history", "--format", "json")
		events = result.stdout.lines.map { |line| JSON.parse(line, symbolize_names: true) }

		match { events.find { |event| event[:name] == "Leaky › sets ENV" } => { leaks: [{ kind: "env", message: "ENV wasn't restored: added LEAKY_TOKEN." }] } }
		match { events.find { |event| event[:name] == "Leaky › joins its thread" } => { leaks: nil } }
	end

	test "--leaks takes warn, fail or off", timeout: 20 do
		match { leaky.run("--leaks", "fial") => { stderr: /--leaks takes warn, fail or off, not "fial"\.\nDid you mean fail\?/, exit_status: 2 } }
	end
end
