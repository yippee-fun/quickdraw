# frozen_string_literal: true

# Reporters render a run. Each receives every event:
#
#   start(processes:, worker_choice:, seed:, estimate:)
#   result(path, test, result)
#   load_failed(path, error)
#   tick                        at least once a second, for live displays
#   finish(outcome)
#
# `estimate` is how many tests the run is expected to have and how long it's
# expected to take, from the last run of the same tests, or nil.
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

	# Environment variables set by AI coding agents, which get the agent format
	# unless another is asked for.
	AGENT_VARIABLES = ["CLAUDECODE", "CODEX_SANDBOX", "CURSOR_AGENT", "GEMINI_CLI", "AI_AGENT"].freeze

	Estimate = Data.define(:tests, :duration)

	def self.agent?
		AGENT_VARIABLES.any? { |name| ENV[name] && !ENV[name].empty? }
	end

	# How to run Quickdraw again, for rerun commands.
	def self.command
		program = File.basename($PROGRAM_NAME)
		program = "quickdraw" unless program in "qt" | "quickdraw"
		ENV.key?("BUNDLE_GEMFILE") ? "bundle exec #{program}" : program
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

		# Quoted for a POSIX shell when it contains anything but safe characters.
		private def shell_quote(argument)
			%r{\A[\w./:@%+=-]+\z}.match?(argument) ? argument : "'#{argument.gsub("'", %q('\\\''))}'"
		end

		private def pluralize(count, noun)
			"#{count} #{noun}#{'s' unless count == 1}"
		end

		private def indent(text, spaces)
			text.gsub(/^(?=.)/, " " * spaces)
		end

		# The stripped source at `line` of `path`, or nil if it can't be read or
		# is blank. Read as UTF-8 whatever the locale, as Ruby reads source files.
		private def source_line(path, line)
			@source_lines ||= {}

			lines = @source_lines.fetch(path) do
				@source_lines[path] = File.readlines(path, encoding: Encoding::UTF_8).map(&:scrub)
			rescue SystemCallError
				@source_lines[path] = nil
			end

			code = lines&.[](line - 1)&.strip
			code unless code.nil? || code.empty?
		end

		private def rerun_command(path, test)
			"#{Quickdraw::Reporters.command} #{shell_quote(test ? "#{path}:#{test['line']}" : path)}"
		end
	end
end
