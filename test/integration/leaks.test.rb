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
		skip "Leak checks need fork" unless Process.respond_to?(:fork)

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

	test "doesn't count a killed child that Process.detach is still to reap", timeout: 20 do
		skip "Leak checks need fork" unless Process.respond_to?(:fork)

		result = project("detached.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--leaks", "fail", "--format", "agent")
			class Detached < Quickdraw::Test
				20.times do |index|
					test("kills a detached child \#{index}") do
						pid = spawn("sleep", "10")
						Process.detach(pid)
						Process.kill(:KILL, pid)
						assert true
					end
				end
			end
		RUBY

		assert(result.success?) { result.output }
		refute_includes result.output, "LEAK"
	end

	test "doesn't count a detached child that's still running", timeout: 20 do
		skip "Leak checks need fork" unless Process.respond_to?(:fork)

		result = project("daemon.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--leaks", "fail", "--format", "agent")
			class Daemon < Quickdraw::Test
				test("detaches a child") { Process.detach(spawn("sleep", "1")); assert true }
				test("starts another") { spawn("sleep", "1"); assert true }
			end
		RUBY

		refute_includes result.stdout, "detaches a child"
		assert_match result.stdout, /^ERROR daemon\.test\.rb:3 Daemon › starts another: Quickdraw::Leak: Child process \d+ \(sleep\) is still running\.$/
	end

	test "reports a child process that exited without being waited for", timeout: 20 do
		skip "Leak checks need fork" unless Process.respond_to?(:fork)

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
		skip "Leak checks need fork" unless Process.respond_to?(:fork)

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
		skip "Leak checks need fork" unless Process.respond_to?(:fork)

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
		skip "Leak checks need fork" unless Process.respond_to?(:fork)

		require "json"
		result = leaky.run("-p", "1", "--no-history", "--format", "json")
		events = result.stdout.lines.map { |line| JSON.parse(line, symbolize_names: true) }

		match { events.find { |event| event[:name] == "Leaky › sets ENV" } => { leaks: [{ kind: "env", message: "ENV wasn't restored: added LEAKY_TOKEN." }] } }
		match { events.find { |event| event[:name] == "Leaky › joins its thread" } => { leaks: nil } }
	end

	test "warns about a fiber scheduler or Ractor left running, a failure after a test, and a thread that died", timeout: 20 do
		skip "Leak checks need fork" unless Process.respond_to?(:fork)

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
							# Required from Ruby 4.1.
							def fiber_interrupt(*) = nil
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

	test "finds threads however they were started, after tests that started none", timeout: 20 do
		skip "Leak checks need fork" unless Process.respond_to?(:fork)

		result = project("threads.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--format", "json")
			class Threads < Quickdraw::Test
				test("starts none") { assert true }
				test("joins") { Thread.new { 1 }.join; assert true }
				test("ends later") { Thread.new { sleep 0.05 }; assert true }
				test("waits") { sleep 0.2; assert true }
				test("start") { Thread.start { sleep }; assert true }
				test("fork") { Thread.fork { sleep }; assert true }
				test("from a thread") { Thread.new { Thread.new { sleep } }.join; assert true }
				test("no assertions") { Thread.new { sleep } }
			end
		RUBY

		leaks = result.events.select { |event| event["leaks"] }.to_h { |event| [event["name"], event["leaks"].map { |leak| leak["message"] }] }

		assert_equal leaks, {
			"Threads › ends later" => ["A thread started at threads.test.rb:4 is still running."],
			"Threads › start" => ["A thread started at threads.test.rb:6 is still running."],
			"Threads › fork" => ["A thread started at threads.test.rb:7 is still running."],
			"Threads › from a thread" => ["A thread started at threads.test.rb:8 is still running."],
			"Threads › no assertions" => ["A thread started at threads.test.rb:9 is still running."],
		}

		assert_includes result.stdout, "This test made no assertions."
	end

	test "finds threads started with a constructor saved before leak tracking", timeout: 20 do
		skip "Leak checks need fork" unless Process.respond_to?(:fork)

		result = project(
			"config/quickdraw.rb" => "$new_thread = Thread.method(:new)\n",
			"saved.test.rb" => <<~RUBY,
				class Saved < Quickdraw::Test
					test("1 starts none") { assert true }
					test("2 saved constructor") { $new_thread.call { sleep }; assert true }
					test("3 starts none") { assert true }
				end
			RUBY
		).run("-p", "1", "--no-history", "--seed", "1", "--format", "json")

		leaks = result.events.select { |event| event["leaks"] }.to_h { |event| [event["name"], event["leaks"].map { |leak| leak["message"] }] }

		assert_equal leaks, { "Saved › 2 saved constructor" => ["A thread started at saved.test.rb:3 is still running."] }
	end

	test "reports a failure after a test from a thread that was running before it", timeout: 20 do
		skip "Leak checks need fork" unless Process.respond_to?(:fork)

		project = project("pool.test.rb" => <<~RUBY)
			$jobs = Thread::Queue.new
			Thread.new { loop { $jobs.pop.call } }

			class Pool < Quickdraw::Test
				test("1 fails late") { $jobs << -> { sleep 0.05; assert false }; assert true }
				test("2 waits") { sleep 0.2; assert true }
			end
		RUBY

		result = project.run("-p", "1", "--no-history", "--seed", "1", "--format", "json")
		leaks = result.events.flat_map { |event| event["leaks"].to_a.map { |leak| leak["message"] } }

		assert_equal leaks, ["After Pool › 1 fails late (line 5) finished, a thread it started failed an assertion at pool.test.rb:5: expected false to be truthy"]
	end

	test "--leaks takes warn, fail or off", timeout: 20 do
		match { leaky.run("--leaks", "fial") => { stderr: /--leaks takes warn, fail or off, not "fial"\.\nDid you mean fail\?/, exit_status: 2 } }
	end
end
