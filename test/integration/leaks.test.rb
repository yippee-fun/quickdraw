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

		assert_match result.stdout, /^LEAK zombie\.test\.rb:2 Zombie › forks: Child process \d+ exited \(status 4\), but wasn't waited for\.$/
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

	test "warns about a fiber scheduler or Ractor left running, a failure after a test, and a thread that died", timeout: 20 do
		project = project(
			"concurrent.test.rb" => <<~RUBY,
				class Concurrent < Quickdraw::Test
					test("1 fails late") { Thread.new { sleep 0.05; assert false }; assert true }
					test("2 waits") { sleep 0.2; assert true }
					test("3 a thread dies") { Thread.new { raise "boom in the background" }; sleep 0.05; assert true }
					test("5 starts a Ractor") { $ractor = Ractor.new { sleep 1 } if defined?(Ractor); assert true }
					test("6 sees its thread's exception") { assert_raises(RuntimeError) { Thread.new { raise "seen" }.join } }
				end
			RUBY
			# On its own, since the scheduler it leaves would change how later tests' threads join.
			"scheduler.test.rb" => <<~RUBY,
				class Scheduler < Quickdraw::Test
					test("sets a scheduler") do
						scheduler = Class.new do
							def fiber(&) = Fiber.new(blocking: false, &).tap(&:resume)
							def block(*) = nil
							def unblock(*) = nil
							def kernel_sleep(*) = nil
							def io_wait(*) = nil
							def close = nil
						end

						Fiber.set_scheduler(scheduler.new)
						assert true
					end
				end
			RUBY
		)

		# Where "2 waits" runs straight after "1 fails late", so its thread fails
		# while a test is running, which reports it.
		result = project.run("-p", "1", "--no-history", "--seed", "1", "--format", "json", "concurrent.test.rb")
		leaks = result.events.select { |event| event["leaks"] }.to_h { |event| [event["name"], event["leaks"].map { |leak| leak["message"] }] }

		assert_includes leaks.values.flatten, "After Concurrent › 1 fails late (line 2) finished, a thread it started failed an assertion at concurrent.test.rb:2: expected false to be truthy"
		assert_includes leaks["Concurrent › 3 a thread dies"], "A thread started at concurrent.test.rb:4 ended with RuntimeError: boom in the background"
		assert_includes leaks["Concurrent › 5 starts a Ractor"], "1 Ractor started here is still running." if defined?(Ractor)
		refute leaks.key?("Concurrent › 6 sees its thread's exception")

		scheduler = project.run("-p", "1", "--no-history", "--format", "json", "scheduler.test.rb")
		assert_match scheduler.events.find { |event| event["leaks"] }["leaks"].first["message"], /\AA fiber scheduler \(.+\) was set and not unset/

		failing = project.run("-p", "1", "--no-history", "--seed", "1", "--leaks", "fail", "--format", "agent", "concurrent.test.rb:4")
		assert_includes failing.stdout, "Quickdraw::Leak: A thread started at concurrent.test.rb:4 ended with RuntimeError"
	end

	test "--leaks takes warn, fail or off", timeout: 20 do
		match { leaky.run("--leaks", "fial") => { stderr: /--leaks takes warn, fail or off, not "fial"\.\nDid you mean fail\?/, exit_status: 2 } }
	end
end
