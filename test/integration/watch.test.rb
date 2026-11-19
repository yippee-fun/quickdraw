# frozen_string_literal: true

require_relative "../support/integration"

class WatchTest < Quickdraw::Test
	include Integration

	def calculator = project(
		"lib/calculator.rb" => "def add(a, b) = a + b\n",
		"test/calculator.test.rb" => <<~RUBY,
			require_relative "../lib/calculator"

			class Calculator < Quickdraw::Test
				test("adds") { assert_equal add(1, 2), 3 }
			end
		RUBY
		"test/other.test.rb" => <<~RUBY,
			class Other < Quickdraw::Test
				test("fails") { assert false }
				test("passes") { assert true }
			end
		RUBY
	)

	def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

	# Steps run in order, each once the output has shown `Watching` one more
	# time, then the watcher is quit.
	def watch(project, *steps)
		project.run("-p", "1", "--watch", tty: [40, 120], timeout: 30) do |output, keyboard|
			watching = output.scan(/^Watching/).size
			next if watching == 0 || watching == @steps_taken

			@steps_taken = watching
			step = steps[watching - 1]
			step ? step.call(keyboard) : keyboard.write("q")
		end
	end

	test "reruns only the tests for a changed file", timeout: 40 do
		project = calculator
		source = File.join(project.directory, "lib/calculator.rb")
		saves = 0
		saved_at = nil
		quit = false

		# Saved again if nothing happens, in case the first save came too soon.
		result = project.run("-p", "1", "--watch", tty: [40, 120], timeout: 30) do |output, keyboard|
			case output.scan(/^Watching/).size
			in 1 if saved_at.nil? || now - saved_at > 1
				saves += 1
				File.write(source, "def add(a, b) = a + b + #{saves} - #{saves}\n")
				saved_at = now
			in 2 unless quit
				keyboard.write("q")
				quit = true
			else nil
			end
		end

		assert result.success?
		assert_includes result.stdout, "Changed lib/calculator.rb, so running test/calculator.test.rb"
		assert_match result.stdout, %r{Changed lib/calculator\.rb.*\n  Tests   1 test · 1 assertion}m
	end

	test "keys run only failures, filter by name and path, and run everything again", timeout: 40 do
		result = watch(
			calculator,
			-> (keyboard) { keyboard.write("f") },
			-> (keyboard) { keyboard.write("a") },
			-> (keyboard) { keyboard.write("n") && sleep(0.2) && keyboard.write("passes\n") },
			-> (keyboard) { keyboard.write("p") && sleep(0.2) && keyboard.write("calculator\n") },
			-> (keyboard) { keyboard.write("\r") },
		)

		assert result.success?
		runs = result.stdout.scan(/^  Tests   \K\d+ tests? · .*$/)
		assert_equal runs.map { |run| run[/\A\d+ tests?/] }, ["3 tests", "1 test", "3 tests", "1 test", "0 tests", "0 tests"]
		assert_includes result.stdout, "Watching (failed) · Enter rerun"
		assert_includes result.stdout, "Watching (name matches passes) · Enter rerun"
		assert_includes result.stdout, "Watching (path contains calculator, name matches passes) · Enter rerun"
	end

	test "a name filter narrows --name rather than adding to it", timeout: 40 do
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--watch", "--name", "api", tty: [40, 120], timeout: 30) do |output, keyboard|
			class A < Quickdraw::Test
				test("api users") { assert true }
				test("api orders") { assert true }
				test("database users") { assert true }
			end
		RUBY
			case output.scan(/^Watching/).size
			in 1 if !@typed
				keyboard.write("n")
				sleep 0.2
				keyboard.write("users\n")
				@typed = true
			in 2 if !@quit
				keyboard.write("q")
				@quit = true
			else nil
			end
		end

		assert_equal result.stdout.scan(/^  Tests   \K\d+ tests?/), ["2 tests", "1 test"]
	end

	test "f explains that it needs run history with --no-history", timeout: 40 do
		without_history = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n")
		result = without_history.run("-p", "1", "--watch", "--no-history", tty: [40, 120], timeout: 30) do |output, keyboard|
			case output.scan(/^Watching/).size
			in 1 if !@pressed
				keyboard.write("f")
				@pressed = true
			in 2 if !@quit
				keyboard.write("q")
				@quit = true
			else nil
			end
		end

		assert_includes result.stdout, "Running only failures needs run history, which --no-history turned off."
		refute File.exist?(File.join(without_history.directory, ".quickdraw"))
	end

	test "keeps a machine-readable report clean, with messages on stderr", timeout: 40 do
		require "json"
		result = calculator.run("-p", "1", "--watch", "--format", "json", interrupt_when: /^Watching/, timeout: 30)

		assert result.success?
		assert_includes result.stderr, "Watching"
		result.stdout.each_line { |line| JSON.parse(line) }
	end
end
