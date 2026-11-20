# frozen_string_literal: true

# Reporters render a run. Each receives every event:
#
#   start(processes:, worker_choice:, seed:, paths:, estimate:)
#   result(path, test, result)
#   finished_file(path)         once each of its tests has its final result
#   load_failed(path, error)
#   pause / resume              around a debugger having the terminal
#   finish(outcome)
#
# and answers `shows_loading_output?`: whether it shows what loading test
# files printed, in order with its own output. If so, it gets it from:
#
#   printed(output)
#
# `paths` are the test files the run will load. `estimate` is how many tests
# the run is expected to have and how long it's expected to take, from the
# last run of the same tests, or nil.
#
# They run in the coordinator, after the loader has forked, so they may load
# libraries (such as json) as long as they do it lazily, not at construction.
module Quickdraw::Reporters
	autoload :Human, "quickdraw/reporters/human"
	autoload :Agent, "quickdraw/reporters/agent"
	autoload :JSON, "quickdraw/reporters/json"
	autoload :GitHubActions, "quickdraw/reporters/github_actions"
	autoload :JUnit, "quickdraw/reporters/junit"
	autoload :Multiple, "quickdraw/reporters/multiple"
	autoload :LastRun, "quickdraw/reporters/last_run"

	# Environment variables set by AI coding agents, which get the agent format
	# unless another is asked for.
	AGENT_VARIABLES = ["CLAUDECODE", "CODEX_SANDBOX", "CURSOR_AGENT", "GEMINI_CLI", "AI_AGENT"].freeze

	# From the last run of the same tests: how many there were, how long the run
	# took, and the total of their durations.
	Estimate = Data.define(:tests, :duration, :test_time)

	def self.agent?
		AGENT_VARIABLES.any? { |name| ENV[name] && !ENV[name].empty? }
	end

	# How to run Quickdraw again, for rerun commands.
	def self.command
		program = File.basename($PROGRAM_NAME)
		program = "quickdraw" unless program in "qt" | "quickdraw"
		ENV.key?("BUNDLE_GEMFILE") ? "bundle exec #{program}" : program
	end

	# Quoted for a POSIX shell when it contains anything but safe characters.
	def self.shell_quote(argument)
		%r{\A[\w./:@%+=-]+\z}.match?(argument) ? argument : "'#{argument.gsub("'", %q('\\\''))}'"
	end

	module Formatting
		ANSI = /\e\[[\d;]*m/

		# With trailing slashes, so they can't match paths like "exercises".
		LIBRARY = "#{Quickdraw::LIB}/"
		EXECUTABLES = "#{File.expand_path('../exe', Quickdraw::LIB)}/"

		private def name_of(test)
			Quickdraw::Filter.name_of(test)
		end

		# Quickdraw's own frames are dropped wherever they are, since an error can
		# be raised inside an assertion. Everything from Quickdraw's executable on
		# is the runner starting up.
		private def user_backtrace(frames)
			user_frames = frames
				.reject { |frame| frame.start_with?(LIBRARY) }
				.take_while { |frame| !frame.start_with?(EXECUTABLES) }

			user_frames.empty? ? frames : user_frames
		end

		private def relative(path)
			path.delete_prefix("#{Dir.pwd}/")
		end

		private def relative_paths(text)
			text.gsub("#{Dir.pwd}/", "")
		end

		private def plain(text)
			Quickdraw.utf8(text).gsub(ANSI, "")
		end

		# The path and line of a backtrace frame ("path:line:in 'method'"), or nil.
		# Greedy, since paths can contain colons.
		private def frame_location(frame)
			match = /\A(?<path>.+):(?<line>\d+)(?::in |\z)/.match(frame)
			[match[:path], Integer(match[:line], 10)] if match
		end

		private def shell_quote(argument) = Quickdraw::Reporters.shell_quote(argument)

		private def pluralize(count, noun)
			"#{count} #{noun}#{'s' unless count == 1}"
		end

		private def indent(text, spaces)
			text.gsub(/^(?=.)/, " " * spaces)
		end

		# The stripped source at `line` of `path`, or nil if it can't be read or
		# is blank. Read as UTF-8 whatever the locale, as Ruby reads source files.
		private def source_line(path, line)
			code = source_lines(path)&.[](line - 1)&.strip
			code unless code.nil? || code.empty?
		end

		# The lines of `path`, or nil if it can't be read.
		private def source_lines(path)
			@source_lines ||= {}

			@source_lines.fetch(path) do
				@source_lines[path] = File.readlines(path, chomp: true, encoding: Encoding::UTF_8).map(&:scrub)
			rescue SystemCallError
				@source_lines[path] = nil
			end
		end

		private def rerun_command(path, test)
			"#{Quickdraw::Reporters.command} #{shell_quote(test ? "#{path}:#{test['line']}" : path)}"
		end

		# For a test that failed, then passed when retried.
		private def flaky_explanation(result)
			# A run kept by an older Quickdraw has no attempts.
			attempts = result["attempts"] || []
			passed_in = attempts.last&.fetch("in") || "fresh worker"
			fresh = attempts.count { |attempt| attempt["in"] == "fresh worker" }
			retry_number = " (fresh worker #{fresh})" if fresh > 1

			case [result["flake"], passed_in]
			in ["nondeterministic", "same worker"]
				"Passed when run again in the same worker, so it fails some of the time on its own."
			in ["nondeterministic", _]
				"Failed again in a fresh worker, then passed in another#{retry_number}, so it fails some of the time on its own."
			in ["order_dependent", _]
				"Failed again in the same worker, then passed in a fresh one#{retry_number}, so it likely depends on tests that ran before it."
			else
				"Passed when retried in a fresh worker#{retry_number}, so it’s flaky or depends on tests that ran before it."
			end
		end

		# Whether bisecting could find what a flaky test depends on.
		private def bisect?(result)
			result["in_history"] && result["flake"] != "nondeterministic"
		end

		private def bisect_command(path, test)
			"#{Quickdraw::Reporters.command} bisect #{shell_quote("#{path}:#{test['line']}")}"
		end
	end
end
