# frozen_string_literal: true

require_relative "../support/integration"

class OutputTest < Quickdraw::Test
	include Integration

	NOISY = <<~RUBY
		puts "printed while loading"

		class Noisy < Quickdraw::Test
			test("fails") do
				puts "from puts"
				warn "from warn"
				system("echo from a subprocess")
				$stdout.syswrite("from a syscall\\n")
				assert false
			end

			test("passes") { puts "from a passing test"; assert true }
		end
	RUBY

	def noisy = project(
		"config/quickdraw.rb" => "puts 'printed while booting'\n",
		"noisy.test.rb" => NOISY,
	)

	test "shows what a failing test printed with its failure, and hides what passing tests print", timeout: 20 do
		result = noisy.run("-p", "1", "--no-history", "--format", "human")

		refute result.success?
		assert_includes result.stdout, "  Output\n    from puts\n    from warn\n    from a subprocess\n    from a syscall\n"
		refute_includes result.output, "from a passing test"
		assert_includes result.output, "printed while booting"
		assert_includes result.output, "printed while loading"
	end

	test "--no-capture shows what tests print as they print it", timeout: 20 do
		result = noisy.run("-p", "1", "--no-history", "--no-capture", "--format", "human")

		assert_includes result.output, "from a passing test"
		assert_includes result.output, "from a subprocess"
		refute_includes result.output, "  Output\n"
	end

	test "shows the end of a failing test's output for agents", timeout: 20 do
		result = project("long.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--format", "agent")
			class Long < Quickdraw::Test
				test("prints a lot") { 30.times { |i| puts "line \#{i}" }; assert false }
			end
		RUBY

		assert_includes result.stdout, "  Output (last 20 of 30 lines):\n    line 10\n"
		refute_includes result.stdout, "line 9\n"
	end

	test "keeps only the end of very long output", timeout: 20 do
		result = project("huge.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--format", "human")
			class Huge < Quickdraw::Test
				test("prints a lot") { $stdout.write("x" * 100_000); puts "the end"; assert false }
			end
		RUBY

		assert_match result.stdout, /\[\d+ earlier bytes not shown\]/
		assert_includes result.stdout, "the end"
		assert_operator result.stdout.bytesize, :<, 80_000
	end

	test "shows what a test printed before it crashed or hung", timeout: 20 do
		result = project("crash.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--format", "human")
			class Crash < Quickdraw::Test
				test("crashes") { puts "before crashing"; exit!(3) }
				test("hangs", timeout: 0.3) { system("echo before hanging"); sleep }
				test("passes") { assert true }
			end
		RUBY

		assert_includes result.stdout, "Quickdraw::WorkerCrashed: The worker process exited unexpectedly.\n\n  Output\n    before crashing\n"
		assert_match result.stdout, /Quickdraw::Timeout: .*\n(?:    .*\n)*\n  Output\n    before hanging\n/
		match { result => { summary: /\A3 tests · 1 assertion · 2 errored/ } }
	end

	test "Ctrl-C shows what the interrupted test printed", timeout: 20 do
		# A copy of stdout from before capture starts, to say when to press Ctrl-C.
		result = project(
			"config/quickdraw.rb" => "Quickdraw.configure { |config| config.after_forking { $terminal = STDOUT.dup } }\n",
			"a.test.rb" => <<~RUBY,
				class A < Quickdraw::Test
					def teardown = puts("tore down")

					test("waits") { puts "captured"; $terminal.puts "started"; sleep 10 }
				end
			RUBY
		).run("-p", "1", "--no-history", "--format", "human", interrupt_when: /started/)

		assert_equal result.status.exitstatus, 130
		assert_includes result.output, "captured\ntore down\n"
	end

	test "Ctrl-C shows what the interrupted test printed even if its teardown has to be stopped", timeout: 20 do
		result = project(
			"config/quickdraw.rb" => "Quickdraw.configure { |config| config.after_forking { $terminal = STDOUT.dup } }\n",
			"a.test.rb" => <<~RUBY,
				class A < Quickdraw::Test
					def teardown = sleep(30)

					test("waits") { puts "captured"; $terminal.puts "started"; sleep 30 }
				end
			RUBY
		).run("-p", "1", "--no-history", "--format", "human", interrupt_when: /started/)

		assert_equal result.status.exitstatus, 130
		assert_includes result.output, "captured\n"
	end
end
