# frozen_string_literal: true

require_relative "../support/integration"

class WatchTest < Quickdraw::Test
	include Integration

	def setup
		super
		skip "Watch mode needs fork" unless Process.respond_to?(:fork)
	end

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

	# Config that counts the times it boots, and notes when the loader exits by
	# itself, in logs, which watch mode ignores.
	BOOT_COUNTER = <<~RUBY
		File.write("boots.log", "x", mode: "a")
		loader = Process.pid
		at_exit { File.write("exited.log", "x", mode: "a") if Process.pid == loader }
	RUBY

	def boots(project) = File.read(File.join(project.directory, "boots.log")).size

	def summaries(result) = Integration.summaries(result.stdout)

	test "keeps config booted between runs, and stops its loader when quitting", timeout: 40 do
		project = project(
			"config/quickdraw.rb" => BOOT_COUNTER,
			"test/a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n",
		)

		result = watch(project, -> (keyboard) { keyboard.write("\r") }, -> (keyboard) { keyboard.write("\r") })

		assert result.success?
		assert_equal summaries(result).size, 3
		assert_equal boots(project), 1
		assert_equal File.read(File.join(project.directory, "exited.log")), "x"
	end

	test "stops its loader on Ctrl-C", timeout: 40 do
		project = project(
			"config/quickdraw.rb" => BOOT_COUNTER,
			"test/a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n",
		)

		project.run("-p", "1", "--watch", tty: [40, 120], interrupt_when: /^Watching/, timeout: 30)

		assert_equal File.read(File.join(project.directory, "exited.log")), "x"
	end

	test "boots again when config, or a file it loaded, changes, but not for a file only tests load", timeout: 40 do
		project = project(
			"config/quickdraw.rb" => "#{BOOT_COUNTER}require_relative '../lib/helper'\n",
			"lib/helper.rb" => "HELPER = 1\n",
			"lib/calculator.rb" => "def add(a, b) = a + b\n",
			"test/calculator.test.rb" => <<~RUBY,
				require_relative "../lib/calculator"

				class Calculator < Quickdraw::Test
					test("adds") { assert_equal add(1, 2), 3 }
					test("helps") { assert_equal HELPER, 2 }
				end
			RUBY
		)

		result = project.watch(
			{ "lib/calculator.rb" => "def add(a, b) = b + a\n" },
			{ "lib/helper.rb" => "HELPER = 2\n" },
			{ "config/quickdraw.rb" => "#{BOOT_COUNTER}require_relative '../lib/helper'\n" },
		)

		assert result.success?
		assert_equal summaries(result).map { |summary| summary[/\d+ (?:failed|errored)|\z/] }, ["1 failed", "1 failed", "", ""]
		assert_equal boots(project), 3
	end

	# Even with a reloader, which is given changed files, not directories.
	test "boots again when a directory holding files config loaded moves", timeout: 40 do
		project = project(
			"config/quickdraw.rb" => <<~RUBY,
				#{BOOT_COUNTER}
				Dir[File.join(__dir__, "../lib/**/*.rb")].each { |path| require path }
				Quickdraw.configure { |config| config.reloader { |paths| paths.grep(/\\.rb\\z/).each { |path| load path }; true } }
			RUBY
			"lib/support/helper.rb" => "HELPER = 1\n",
			"test/a.test.rb" => "class A < Quickdraw::Test; test('a') { assert_equal HELPER, 1 }; end\n",
		)

		lib = File.join(project.directory, "lib")
		result = watch(project, -> (_keyboard) { File.rename(File.join(lib, "support"), File.join(lib, "extra")) })

		assert result.success?
		assert_equal summaries(result).size, 2
		assert_equal boots(project), 2
	end

	test "boots again once broken config is fixed", timeout: 40 do
		project = project(
			"config/quickdraw.rb" => "raise 'broken'\n",
			"test/a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n",
		)

		result = project.watch({ "config/quickdraw.rb" => "" })

		assert result.success?
		assert_includes result.stdout, "broken"
		assert_match summaries(result).last, /\A1 test · 1 assertion/
	end

	test "starts a loader again when it dies", timeout: 40 do
		project = project(
			"config/quickdraw.rb" => BOOT_COUNTER,
			"test/a.test.rb" => <<~RUBY,
				class A < Quickdraw::Test
					test("kills its loader the first time") do
						Process.kill("KILL", Process.ppid) unless File.exist?("killed.log")
						File.write("killed.log", "")
						assert true
					end
				end
			RUBY
		)

		result = watch(project, -> (keyboard) { keyboard.write("\r") })

		assert result.success?
		assert_equal boots(project), 2
		assert_match summaries(result).last, /\A1 test · 1 assertion/
	end

	test "keeps a group's loader booted after its first run", timeout: 40 do
		project = project(
			"config/quickdraw.rb" => <<~RUBY,
				Quickdraw.configure do |config|
					config.group(:slow, "test/slow/**/*.test.rb") { File.write("group_boots.log", "x", mode: "a") }
				end
			RUBY
			"test/slow/a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n",
			"test/b.test.rb" => "class B < Quickdraw::Test; test('b') { assert true }; end\n",
		)

		result = watch(project, -> (keyboard) { keyboard.write("\r") }, -> (keyboard) { keyboard.write("\r") })

		assert result.success?
		assert_equal summaries(result).map { |summary| summary[/\A\d+ tests?/] }, ["2 tests"] * 3
		# Once for the first run, and once more to keep it booted.
		assert_equal File.read(File.join(project.directory, "group_boots.log")).size, 2
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
		after_change = result.stdout[%r{Changed lib/calculator\.rb.*\z}m]
		assert_match Integration.summaries(after_change).first, /\A1 test · 1 assertion/
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
		runs = summaries(result)
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

		assert_equal summaries(result).map { |summary| summary[/\A\d+ tests?/] }, ["2 tests", "1 test"]
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
