# frozen_string_literal: true

require_relative "../support/integration"

class DebuggerTest < Quickdraw::Test
	include Integration

	# What each prints as a session starts, its prompt, and how to leave it.
	IRB = { stop: "binding.irb", session: "From: ", prompt: /\):\d+> /, leave: "exit" }.freeze
	PRY = { require: "pry", stop: "binding.pry", session: "From: ", prompt: /pry\(.*?\)> /, leave: "exit" }.freeze
	DEBUG = { require: "debug", stop: "debugger", session: /\[\d+, \d+\] in /, prompt: "(rdbg) ", leave: "c" }.freeze
	STYLE = "(?:\e\\[[\\d;]*m)*"

	# Each test stops in the debugger while the other is running, and only
	# passes if what's typed into the debugger changes it. Their timeouts are
	# shorter than the debugger takes.
	def stopping(debugger)
		files = ["a", "b"].to_h do |name|
			["#{name}.test.rb", <<~RUBY]
				#{"require #{debugger[:require].inspect}" if debugger[:require]}
				class #{name.upcase} < Quickdraw::Test
					test("#{name}", timeout: 0.5) do
						sleep 0.3
						x = 1
						#{debugger[:stop]}
						assert_equal x, 2
					end
				end
			RUBY
		end

		project(".irbrc" => "IRB.conf[:SAVE_HISTORY] = nil\n", **files)
	end

	# Types each of `lines` into each session, once the debugger asks for it,
	# then quits watch mode. irb runs a line typed ahead as Ruby rather than as
	# a command, so `exit` would exit the worker.
	def debug(*arguments, debugger: IRB, first: nil)
		skip "This Ruby has no PTY" unless terminal?

		project = stopping(debugger)
		answers = ["x = 2", debugger[:leave]]
		sessions = 0
		lines = []
		from = 0
		typed = nil
		cursor_queries = 0
		seen = 0

		project.run(*arguments, env: { "IRBRC" => File.join(project.directory, ".irbrc"), "IRB_USE_AUTOCOMPLETE" => "false" }, tty: [40, 120], timeout: 30) do |output, keyboard|
			# Answered, as a terminal would, with where the cursor is.
			queries = output.scan("\e[6n").size
			keyboard.write("\e[1;1R" * (queries - cursor_queries))
			cursor_queries = queries

			# Typing waits until the output settles, as a person's would, or Reline
			# can take it as part of the answer.
			settled = output.size == seen
			seen = output.size
			next unless settled

			if output.scan(debugger[:session]).size > sessions
				lines = (sessions == 0 && first) ? first.dup : answers.dup
				sessions += 1
				from = output.rindex(debugger[:session])
				# What was typed into the last session was echoed before this one began.
				typed = nil
			end

			if typed
				# How the terminal shows what was typed, which may be highlighted or
				# followed by a hint.
				echo = (typed == "\x03") ? "^C" : typed
				match = Regexp.new("#{echo.chars.map { |char| Regexp.escape(char) }.join(STYLE)}[^\r]*\r").match(output, from) or next
				from = match.end(0)
				typed = nil
			end

			if lines.any? && output.index(debugger[:prompt], from)
				typed = lines.shift
				keyboard.write((typed == "\x03") ? typed : "#{typed}\n")
			elsif sessions == 2 && lines.empty? && output.index("Watching", from)
				keyboard.write("q")
				sessions += 1
			end
		end
	end

	def passed(result)
		match { result => { summary: /\A2 tests · 2 assertions · [\d.]+s\z/, exit_status: 0 } }
	end

	test "gives the terminal to one binding.irb at a time, in a parallel run", timeout: 40 do
		skip "More than one worker needs fork" unless Process.respond_to?(:fork)

		result = debug("-p", "2")

		passed(result)
		assert_equal result.output.scan(IRB[:session]).size, 2
	end

	test "leaves Ctrl-C to the debugger rather than stopping the run", timeout: 40 do
		skip "On JRuby, the terminal isn't the run's controlling terminal, so Ctrl-C typed in it sends no signal" if RUBY_ENGINE == "jruby"

		result = debug("-p", "2", first: ["\x03", "x = 2", "exit"])

		assert_includes result.output, "^C"
		passed(result)
	end

	test "works in watch mode, which reads keys between runs", timeout: 40 do
		skip "Watch mode needs fork" unless Process.respond_to?(:fork)

		result = debug("-p", "2", "--watch")

		assert_equal result.output.scan(IRB[:session]).size, 2
		passed(result)
	end

	test "works with binding.pry", timeout: 40 do
		skip "pry isn’t in the bundle" unless bundled?("pry")

		passed(debug("-p", "2", debugger: PRY))
	end

	test "works with the debug gem, stopping in the test rather than in Quickdraw", timeout: 40 do
		skip "debug isn’t in the bundle" unless bundled?("debug")

		result = debug("-p", "2", debugger: DEBUG)

		passed(result)
		assert_match result.output, /=>\s+6\|\s+debugger\r/
		refute_includes result.output, "quickdraw/debugger.rb"
	end

	test "works with binding.break", timeout: 40 do
		skip "debug isn’t in the bundle" unless bundled?("debug")

		passed(debug("-p", "2", debugger: { **DEBUG, stop: "binding.break" }))
	end

	test "runs binding.irb typed at the debug gem's prompt, which already has the terminal", timeout: 40 do
		skip "debug isn’t in the bundle" unless bundled?("debug")

		result = debug("-p", "2", debugger: { **DEBUG, prompt: /\(rdbg\) |\):\d+> / }, first: ["binding.irb", "x = 2", "exit", "c"])

		assert_match result.output, IRB[:prompt]
		passed(result)
	end
end
