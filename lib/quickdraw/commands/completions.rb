# frozen_string_literal: true

# Shell completion scripts, generated from the CLI's own options and commands,
# for both `quickdraw` and `qt`.
class Quickdraw::Commands::Completions
	PROGRAMS = ["quickdraw", "qt"].freeze
	# Options that can be given more than once.
	REPEATABLE = ["--name", "--exclude", "--format"].freeze

	Option = Data.define(:long, :short, :argument, :description)

	INSTALL = <<~TEXT
		Usage: quickdraw completions SHELL

		bash  Add to ~/.bashrc:                   eval "$(quickdraw completions bash)"
		zsh   Add to ~/.zshrc, after compinit:    eval "$(quickdraw completions zsh)"
		fish  Add to ~/.config/fish/config.fish:  quickdraw completions fish | source
	TEXT

	def initialize(args, io: $stdout)
		@args = args
		@io = io
	end

	def call
		case @args
		in ["bash"] then @io.puts bash
		in ["zsh"] then @io.puts zsh
		in ["fish"] then @io.puts fish
		else
			warn INSTALL
			return 2
		end

		0
	end

	private def options
		require "optparse"

		Quickdraw::CLI.new([]).option_parser.top.list.grep(OptionParser::Switch).map do |switch|
			Option.new(
				long: switch.long.first,
				short: switch.short.first,
				argument: switch.arg&.strip&.split&.first,
				description: Array(switch.desc).join(" "),
			)
		end
	end

	private def commands
		Quickdraw::Commands::LIST.map { |name, _constant, _arguments, summary| [name, summary] }
	end

	private def formats = Quickdraw::CLI::FORMATS

	private def bash
		words = [*options.flat_map { |option| [option.long, option.short].compact }, *commands.map(&:first)]

		<<~BASH
			# One per line, so a path with spaces stays whole.
			_quickdraw_files() {
				local file
				while IFS= read -r file; do COMPREPLY+=("$file"); done < <(compgen -f -- "$1")
			}

			_quickdraw() {
				local current="${COMP_WORDS[COMP_CWORD]}" previous="${COMP_WORDS[COMP_CWORD-1]}"
				COMPREPLY=()

				case "$previous" in
					--format) COMPREPLY=($(compgen -W "#{formats.join(' ')}" -- "$current")); return ;;
					completions) COMPREPLY=($(compgen -W "bash zsh fish" -- "$current")); return ;;
				esac

				if [[ "$current" == -* ]]; then
					COMPREPLY=($(compgen -W "#{words.grep(/\A-/).join(' ')}" -- "$current"))
				elif [[ $COMP_CWORD -eq 1 ]]; then
					COMPREPLY=($(compgen -W "#{commands.map(&:first).join(' ')}" -- "$current"))
					_quickdraw_files "$current"
				else
					_quickdraw_files "$current"
				fi
			}

			complete -o filenames -F _quickdraw #{PROGRAMS.join(' ')}
		BASH
	end

	private def zsh
		specs = options.map do |option|
			names = [option.short, option.long].compact

			flags = if REPEATABLE.include?(option.long)
				(names.size > 1) ? "'*'{#{names.join(',')}}" : "'*'#{names.first}"
			elsif names.size > 1
				# Both forms of an option exclude each other.
				"'(#{names.join(' ')})'{#{names.join(',')}}"
			else
				names.first
			end
			value = case option.argument
			in nil then ""
			in "FORMAT[:PATH]" then ":format:(#{formats.join(' ')})"
			in "PATH" then ":path:_files"
			in argument then ":#{argument.downcase}:"
			end

			"#{flags}'[#{zsh_escape(option.description)}]#{value}'"
		end

		command_list = commands.map { |name, summary| "'#{name}:#{zsh_escape(summary)}'" }.join(" ")

		<<~ZSH
			#compdef #{PROGRAMS.join(' ')}

			_quickdraw() {
				local -a commands=(#{command_list})

				if (( CURRENT == 2 )) && [[ $words[2] != -* ]]; then
					_describe -t commands command commands
					_files
					return
				fi

				case $words[2] in
					completions) _values shell bash zsh fish; return ;;
					counterpart) _files; return ;;
				esac

				_arguments -s \\
					#{specs.join(" \\\n\t\t")} \\
					'*:test file or directory:_files'
			}

			compdef _quickdraw #{PROGRAMS.join(' ')}
		ZSH
	end

	private def fish
		lines = PROGRAMS.flat_map do |program|
			no_command = "not __fish_seen_subcommand_from #{commands.map(&:first).join(' ')}"

			[
				*commands.map { |name, summary| "complete -c #{program} -n '__fish_use_subcommand' -a #{name} -d #{fish_quote(summary)}" },
				"complete -c #{program} -n '__fish_seen_subcommand_from completions' -x -a 'bash zsh fish'",
				*options.map do |option|
					parts = ["complete -c #{program} -n #{fish_quote(no_command)}"]
					parts << "-s #{option.short.delete_prefix('-')}" if option.short
					parts << "-l #{option.long.delete_prefix('--')}" if option.long
					parts << "-x -a #{fish_quote(formats.join(' '))}" if option.argument == "FORMAT[:PATH]"
					parts << "-r" if option.argument && option.argument != "FORMAT[:PATH]"
					parts << "-d #{fish_quote(option.description)}"
					parts.join(" ")
				end,
			]
		end

		lines.join("\n")
	end

	private def zsh_escape(text)
		text.gsub(/[\[\]:'\\]/) { |character| (character == "'") ? %('\\'') : "\\#{character}" }
	end

	private def fish_quote(text)
		"'#{text.gsub(/['\\]/) { |character| "\\#{character}" }}'"
	end
end
