# frozen_string_literal: true

# Subcommands, such as `quickdraw doctor`. Each is a class that takes the
# arguments after its name and whose #call returns an exit status. They run
# instead of tests, so they may load any library.
module Quickdraw::Commands
	autoload :Init, "quickdraw/commands/init"
	autoload :Doctor, "quickdraw/commands/doctor"
	autoload :History, "quickdraw/commands/history"
	autoload :Counterpart, "quickdraw/commands/counterpart"
	autoload :Completions, "quickdraw/commands/completions"
	autoload :Flaky, "quickdraw/commands/flaky"
	autoload :Bisect, "quickdraw/commands/bisect"
	autoload :Mutate, "quickdraw/commands/mutate"
	autoload :Browser, "quickdraw/commands/browser"
	autoload :Fuzz, "quickdraw/commands/fuzz"
	autoload :Last, "quickdraw/commands/last"

	# Name, constant, arguments and summary, in the order --help lists them.
	LIST = Quickdraw.deep_freeze([
		["init", :Init, "", "Create config/quickdraw.rb and an example test"],
		["doctor", :Doctor, "", "Check that this machine and project are ready to run tests"],
		["browser", :Browser, " install", "Install the browser, and any driver, that browser tests need"],
		["last", :Last, "", "The last run’s results, for an AI agent that didn’t see it"],
		["history", :History, "", "Recent runs, and the slowest and flakiest tests"],
		["flaky", :Flaky, " [--runs N] …", "Run tests many times in different orders to find flaky ones"],
		["bisect", :Bisect, " PATH:LINE", "Find the tests a failing test depends on running before it"],
		["mutate", :Mutate, " [PATH[:LINE] …]", "Change code in small ways and list the changes no test notices"],
		["fuzz", :Fuzz, " [PATH[:LINE] …]", "Run properties for longer, guided by the code their cases reach"],
		["counterpart", :Counterpart, " PATH", "The test file for a source file, or the source file for a test"],
		["completions", :Completions, " SHELL", "Print completions for bash, zsh or fish"],
	])

	def self.find(name)
		_, constant = LIST.find { |command, *| command == name }
		const_get(constant) if constant
	end

	# Whether git ignores run history, by all of its rules. Without git or a
	# repository, whether .gitignore has a line for it.
	def self.history_ignored?
		system("git", "check-ignore", "--quiet", "--no-index", Quickdraw::CLI::HISTORY_PATH, out: File::NULL, err: File::NULL)

		case $?.exitstatus
		in 0 then true
		in 1 then false
		else
			File.exist?(".gitignore") &&
				File.readlines(".gitignore", chomp: true).any? { |line| line.strip in ".quickdraw" | ".quickdraw/" | "/.quickdraw" | "/.quickdraw/" }
		end
	end

	# Shared by commands that print to a terminal.
	module Output
		private def bold(text) = style(text, 1)
		private def dim(text) = style(text, 2)
		private def red(text) = style(text, 31)
		private def green(text) = style(text, 32)
		private def yellow(text) = style(text, 33)
		private def cyan(text) = style(text, 36)

		# Dark text on a coloured background, as test runs show their verdicts.
		private def label(text, background)
			color? ? "\e[1;30;#{background}m #{text} \e[0m" : text
		end

		# Spaces that line text up with what follows a label of `text`.
		private def beside_label(text)
			" " * ((color? ? text.size + 2 : text.size) + 1)
		end

		# A test as runs show it: its name, then its class and location, dimmed.
		private def test_heading(path, line, class_name, description)
			"#{bold(description || "line #{line}")}  #{dim([class_name, "#{path}:#{line}"].compact.join(' · '))}"
		end

		private def ago(elapsed)
			elapsed = elapsed.clamp(0..)

			case elapsed
			in ...60 then "#{elapsed.floor}s ago"
			in ...3600 then "#{(elapsed / 60).floor}m ago"
			in ...86_400 then "#{(elapsed / 3600).floor}h ago"
			else "#{(elapsed / 86_400).floor}d ago"
			end
		end

		private def style(text, code)
			color? ? "\e[#{code}m#{text}\e[0m" : text
		end

		private def color?
			@io.tty? && !ENV.key?("NO_COLOR")
		end
	end
end
