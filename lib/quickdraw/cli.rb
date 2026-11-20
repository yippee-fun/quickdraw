# frozen_string_literal: true

class Quickdraw::CLI
	DEFAULT_PATTERN = "**/*.test.rb"
	IGNORED_DIRECTORIES = %r{\A(?:vendor|node_modules|tmp)/}
	HISTORY_PATH = ".quickdraw/history.sqlite3"
	FORMATS = ["human", "agent", "json", "junit"].freeze
	# Formats that other programs read, which what tests print would corrupt.
	MACHINE_FORMATS = ["json", "junit"].freeze
	LEAK_MODES = ["warn", "fail", "off"].freeze
	PROFILE_TIMESLICE = "1"
	MAX_SEED = (2 ** 63) - 1

	def initialize(args)
		@args = args
	end

	def call
		# For the last run's report.
		@command_line = [Quickdraw::Reporters.command, *@args.map { |argument| argument.match?(%r{\A[\w./:=@%+,-]+\z}) ? argument : argument.inspect }].join(" ")

		# A file or directory with a command's name is still run as tests.
		case @args
		in ["all" | "browser" => scope, *rest] if !File.exist?(scope) && !(@args in ["browser", "install", *])
			@scope = scope
			@args = rest
		in [name, *] if !File.exist?(name) && (command = Quickdraw::Commands.find(name))
			# Commands don't give out the terminal, though a run that started this one might.
			ENV.delete(Quickdraw::Debugger::FLAG)
			exit(command.new(@args.drop(1)).call)
		else
			nil
		end

		# optparse, etc and anything else needed to parse options load in a
		# throwaway process so they don’t leak into the processes that run tests.
		options = Quickdraw.isolate { parse }

		# Ruby reads the timeslice at boot, so it's set by starting again. See Sampler.
		if options[:profile] && ENV["RUBY_THREAD_TIMESLICE"] != PROFILE_TIMESLICE
			exec({ "RUBY_THREAD_TIMESLICE" => PROFILE_TIMESLICE }, RbConfig.ruby, "-I", Quickdraw::LIB, File.expand_path($PROGRAM_NAME), *@scope, *@args)
		end

		# Forks keep the timeslice; processes that tests start shouldn't get it.
		ENV.delete("RUBY_THREAD_TIMESLICE") if options[:profile]

		# Before any loader starts, so every process knows where to look.
		ENV[Quickdraw::Debugger::FLAG] = File.join(Quickdraw.temporary_directory, "quickdraw-debugging-#{Process.pid}")

		# Before anything forks, so watch mode's loaders and every worker inherit it.
		system("taskpolicy", "-b", "-p", Process.pid.to_s) if options[:efficiency]

		if options[:watch]
			watch(options)
		else
			exit(run(options).exit_status)
		end
	end

	private def parse
		require "optparse"

		# Run settings config can set too (see Configuration#settings) are nil
		# unless given, so config decides.
		options = {
			backtrace: false,
			timings: false,
			timeline: false,
			profile: false,
			coverage: false,
			processes: nil,
			watch: false,
			seed: nil,
			efficiency: false,
			history: true,
			failed: false,
			changed: false,
			fail_fast: false,
			names: [],
			excludes: [],
			browsers: [],
			outputs: [],
		}

		parser = option_parser(options)

		begin
			operands = parser.parse(@args)
		rescue OptionParser::ParseError => error
			usage_error(*explain(parser, error))
		end

		options[:outputs].each do |format, _path|
			next if FORMATS.include?(format)

			suggestion = suggest(format, FORMATS)
			usage_error "#{format} isn’t a format. Use #{FORMATS[...-1].join(', ')} or #{FORMATS.last}.", ("Did you mean #{suggestion}?" if suggestion)
		end

		options[:outputs].map! do |format, path|
			next [format, nil] unless path

			usage_error "--format #{format}: needs a file after the colon." if path.empty?
			path = File.expand_path(path)
			usage_error "#{path} is a directory, so a report can’t be written to it." if File.directory?(path)

			require "fileutils"
			FileUtils.mkdir_p(File.dirname(path))
			writable = File.writable?(File.dirname(path)) && (!File.exist?(path) || File.writable?(path))
			usage_error "Can’t write to #{path}." unless writable

			[format, path]
		rescue SystemCallError => error
			usage_error "Can’t write to #{path} (#{error.message})."
		end

		if options[:outputs].count { |_format, path| path.nil? } > 1
			usage_error "Only one format can write to the terminal.", "Give the others a file, as in --format json:report.json."
		end

		if (flakes_path = options[:flakes_path])
			flakes_path = options[:flakes_path] = File.expand_path(flakes_path)
			usage_error "#{flakes_path} is a directory, so flakes can’t be written to it." if File.directory?(flakes_path)

			begin
				require "fileutils"
				FileUtils.mkdir_p(File.dirname(flakes_path))
			rescue SystemCallError => error
				usage_error "Can’t write to #{flakes_path} (#{error.message})."
			end

			writable = File.writable?(File.dirname(flakes_path)) && (!File.exist?(flakes_path) || File.writable?(flakes_path))
			usage_error "Can’t write to #{flakes_path}." unless writable
		end

		paths = [*options[:outputs].filter_map(&:last), *flakes_path]
		if (duplicate = paths.find { |path| paths.count(path) > 1 })
			usage_error "More than one format would write to #{duplicate}."
		end

		if options[:history] && paths.include?(File.expand_path(Quickdraw::Reporters::LastRun::PATH))
			usage_error "#{Quickdraw::Reporters::LastRun::PATH} keeps the last run, for `quickdraw last`, so a format can’t write there too."
		end

		if options[:timeline] && paths.include?(File.expand_path(Quickdraw::Timeline::PATH))
			usage_error "--timeline writes its chart to #{Quickdraw::Timeline::PATH}, so a format can’t write there too."
		end

		if options[:watch] && options[:outputs].any? { |format, path| format == "junit" && path.nil? }
			usage_error "--watch would write a JUnit document to the terminal on every run.", "Give it a file, as in --format junit:junit.xml."
		end

		if options[:outputs].none? { |_format, path| path.nil? }
			options[:outputs].unshift([Quickdraw::Reporters.agent? ? "agent" : "human", nil])
		end

		if [options[:processes], options[:max], options[:efficiency]].count(&:itself) > 1
			usage_error "Use only one of --processes, --max and --efficiency."
		end

		usage_error "--failed needs run history, so it can’t be used with --no-history." if options[:failed] && !options[:history]
		usage_error "--quarantine needs run history, so it can’t be used with --no-history." if options[:quarantine] && !options[:history]

		if options[:leaks] && !LEAK_MODES.include?(options[:leaks])
			suggestion = suggest(options[:leaks], LEAK_MODES)
			usage_error "--leaks takes #{LEAK_MODES[...-1].join(', ')} or #{LEAK_MODES.last}, not #{options[:leaks].inspect}.", ("Did you mean #{suggestion}?" if suggestion)
		end

		usage_error "--base says what --changed compares with, so it needs --changed." if options[:base] && !options[:changed]

		usage_error "--flakes is for a single run, so it can’t be used with --watch." if options[:flakes_path] && options[:watch]

		if options[:changed]
			usage_error "--changed chooses the test files, so it can’t be used with paths." if operands.any?
			usage_error "--changed can’t be used with --watch, which runs the tests for each change." if options[:watch]
			usage_error "--changed can’t be used with --failed, which chooses the tests too." if options[:failed]
		end

		if options[:efficiency] && !Quickdraw::Platform.m_series?
			usage_error "Efficiency cores are only available on M-series Macs."
		end

		if options[:watch] && !Quickdraw::Platform.supports_forking?
			usage_error "Watch mode needs fork, which this platform doesn’t support."
		end

		if options[:coverage] && !Quickdraw::Platform.supports_forking?
			usage_error "--coverage needs fork, which this platform doesn’t support."
		end

		# Without fork, tests share the coordinator's process, so leaks can't be told apart.
		if options[:leaks] == "fail" && !Quickdraw::Platform.supports_forking?
			usage_error "--leaks fail needs fork, which this platform doesn’t support."
		end

		usage_error "--processes must be at least 1." if options[:processes]&.< 1

		if !Quickdraw::Platform.supports_forking? && (options[:max] || options[:efficiency] || options[:processes]&.>(1))
			warn "More than one worker needs fork, which this platform doesn’t support, so tests run in one."
		end

		# nil lets the coordinator tune the count from run history.
		options[:processes] = if !Quickdraw::Platform.supports_forking?
			1
		elsif options[:max]
			Quickdraw::Platform.cpu_cores
		elsif options[:efficiency]
			Quickdraw::Platform.efficiency_cores
		else
			options[:processes]
		end

		options[:cores] = Quickdraw::Platform.supports_forking? ? Quickdraw::Platform.non_blocking_cores : 1
		# Tests that mostly wait can use more workers than cores; beyond this the
		# memory and scheduling overhead outweighs it.
		options[:max_processes] = Quickdraw::Platform.cpu_cores * 3

		options[:seed] ||= ENV["SEED"]&.then do |it|
			Integer(it, exception: false) || usage_error("SEED must be a whole number, not #{it.inspect}.")
		end
		options[:seed] ||= Random.new_seed % 100_000

		# Seeds are stored in SQLite, whose integers are signed 64-bit.
		usage_error "The seed must be between 0 and #{MAX_SEED}." unless (0..MAX_SEED).cover?(options[:seed])

		options[:patterns] = []
		options[:lines] = {}

		operands.each do |argument|
			path, *lines = split_lines(argument)
			usage_error(*missing_path(path)) if test_files([path]).empty?
			options[:patterns] << path
			(options[:lines][File.realpath(path)] ||= []).concat(lines) if lines.any?
		end

		(options[:names] + options[:excludes]).each do |pattern|
			Quickdraw::Filter::NamePattern.parse(pattern)
		rescue RegexpError => error
			usage_error "#{pattern} isn’t a valid pattern: #{error.message.chomp('.')}."
		end

		options
	end

	# Public for shell completions, which read its switches.
	def option_parser(options = {})
		OptionParser.new do |parser|
			command = Quickdraw::Reporters.command
			paths = "[options] [files, directories, globs or file:line …]"

			parser.banner, *description = case @scope
			in nil
				[
					"#{bold('Usage:')} #{command} #{paths}\n       #{command} COMMAND [arguments]",
					"Runs tests across every core. With no paths, runs #{DEFAULT_PATTERN}.",
					"Browser tests (config.browser’s) run only when given as files, or with --failed or --browser.",
					"#{command} browser runs only them, and #{command} all runs everything.",
				]
			in "browser"
				[
					"#{bold('Usage:')} #{command} browser #{paths}\n       #{command} browser install [chromium|firefox|webkit …]",
					"Runs only the browser tests (config.browser’s) across every core. With no paths, those in #{DEFAULT_PATTERN}.",
					"browser install installs Playwright and the browsers they need, config.browser’s by default.",
				]
			in "all"
				["#{bold('Usage:')} #{command} all #{paths}", "Runs every test, browser tests too, across every core. With no paths, runs #{DEFAULT_PATTERN}."]
			end

			parser.summary_width = 24
			parser.separator ""
			description.each { |line| parser.separator line }

			parser.separator ""
			parser.separator bold("Choosing tests")

			parser.on("-n", "--name PATTERN", "Only tests whose name contains PATTERN, or matches /PATTERN/flags") do |it|
				options[:names] << it
			end

			parser.on("-x", "--exclude PATTERN", "Leave out tests whose name contains PATTERN, or matches /PATTERN/flags") do |it|
				options[:excludes] << it
			end

			parser.on("--browser NAME", "Browser tests only in NAME, one of config.browser’s browsers (or a group’s variant)") do |it|
				options[:browsers] |= [it]
			end

			parser.on("-f", "--failed", "Only the tests that failed or errored in the last run") do
				options[:failed] = true
			end

			parser.on("--changed", "Only the test files that run code changed since the last commit (mapped by --coverage runs)") do
				options[:changed] = true
			end

			parser.on("--base REF", "With --changed, what changed since this branched from REF, as in a pull request") do |ref|
				options[:base] = ref
			end

			parser.on("--fail-fast", "Stop starting tests after the first failure or error") do
				options[:fail_fast] = true
			end

			parser.on(
				"--retry N", Integer,
				"Retry each failure once in the worker it failed in, then up to N times in a fresh worker (default 1, 0 to turn off). A test that passes on retry is flaky, which still fails the run",
			) do |it|
				usage_error "--retry needs 0 or more, not #{it}." if it.negative?
				options[:retries] = it
			end

			parser.on("--[no-]allow-flaky", "Pass the run when every failure passed on retry") do |it|
				options[:allow_flaky] = it
			end

			parser.on("--[no-]quarantine", "Let tests that were flaky in the last #{Quickdraw::History::QUARANTINE_WINDOW} runs fail without failing the run") do |it|
				options[:quarantine] = it
			end

			parser.on("--flakes FILE", "Write the tests that passed on retry, with each attempt, to FILE as JSON") do |it|
				options[:flakes_path] = it
			end

			parser.on("-s N", "--seed N", Integer, "Order tests and seed rand with N (or set SEED)") do |it|
				options[:seed] = it
			end

			parser.separator ""
			parser.separator bold("Output")

			parser.on(
				"--format FORMAT[:PATH]",
				"#{FORMATS.join(', ')}, to the terminal or to PATH. Repeat for more than one",
				"(default: agent under AI coding agents, otherwise human)",
			) do |it|
				format, path = it.split(":", 2)
				options[:outputs] << [format, path]
			end

			parser.on("-t", "--timings", "List the slowest tests and files") do
				options[:timings] = true
			end

			parser.on("--timeline", "Show how workers spent the run, and chart it in #{Quickdraw::Timeline::PATH}") do
				options[:timeline] = true
			end

			parser.on("--profile", "Sample tests and list the methods that take the most of their time") do
				options[:profile] = true
			end

			parser.on("-c", "--coverage", "Measure which lines, branches and methods tests run") do
				options[:coverage] = true
			end

			parser.on("-b", "--backtrace", "Include Quickdraw’s own frames in backtraces") do
				options[:backtrace] = true
			end

			parser.on("--[no-]capture", "With --no-capture, show what tests print as they print it, rather than with their failures") do |it|
				options[:capture] = it
			end

			parser.on("--leaks MODE", "Threads, child processes and ENV changes a test leaves behind: warn (default), fail or off") do |it|
				options[:leaks] = it
			end

			parser.separator ""
			parser.separator bold("Workers")

			parser.on("-p N", "--processes N", Integer, "Run N workers, or fewer where a group's use more than one core, as browser tests' do (default: tuned from run history)") do |it|
				options[:processes] = it
			end

			parser.on("-m", "--max", "One worker per CPU core") do
				options[:max] = true
			end

			parser.on("-e", "--efficiency", "Run on efficiency cores (Apple silicon)") do
				options[:efficiency] = true
			end

			parser.on("--[no-]elastic", "Add workers while tests leave CPU idle, unless the count is given") do |it|
				options[:elastic] = it
			end

			parser.separator ""
			parser.separator bold("Other")

			parser.on("-w", "--watch", "Run again when files change") do
				options[:watch] = true
			end

			parser.on("--no-history", "Don’t read or record run history (#{HISTORY_PATH})") do
				options[:history] = false
			end

			parser.on("-v", "--version", "Print the version") do
				require_relative "version"
				puts "Quickdraw #{Quickdraw::VERSION}"
				exit
			end

			parser.on("-h", "--help", "Print this help") do
				puts help_text(parser)
				exit
			end

			examples = [
				["#{command} test/models", "Every test in a directory"],
				["#{command} test/user.test.rb:12", "The test at line 12"],
				["#{command} -n /admin/i --fail-fast", "Tests matching a regex, stopping at the first failure"],
				["#{command} --failed", "What failed last time"],
				["#{command} all", "Every test, browser tests too"],
			]
			width = examples.map { |example, _| example.size }.max

			parser.separator ""
			parser.separator bold("Commands")

			Quickdraw::Commands::LIST.each do |name, _constant, arguments, summary|
				parser.separator "    #{"#{name}#{arguments}".ljust(parser.summary_width)} #{summary}"
			end

			parser.separator ""
			parser.separator bold("Examples")
			examples.each { |example, description| parser.separator "    #{example.ljust(width)}  #{dim(description)}" }

			parser.separator ""
			parser.separator "Exits with 0 when everything passes, 1 when something fails, 2 for a usage error and 130 when interrupted."
		end
	end

	# The message and hint for an option the parser rejected.
	private def explain(parser, error)
		argument, value = error.args
		option, inline_value = argument.split("=", 2)

		# "-pabc" is -p with the value "abc".
		if (attached = /\A-(?<letter>[^-])(?<rest>.+)\z/.match(option))
			option, inline_value = "-#{attached[:letter]}", attached[:rest]
		end

		value ||= inline_value
		switches = parser.top.list.grep(OptionParser::Switch)
		long_options = switches.flat_map(&:long)
		# Abbreviations, such as --for for --format, as the parser accepts them.
		long = long_options.include?(option) ? option : long_options.select { |it| it.start_with?(option) }.then { |it| it.first if it.one? }
		switch = switches.find { |it| it.long.include?(long) || it.short.include?(option) }
		name = switch&.long&.first || option

		case error
		in OptionParser::InvalidArgument if switch.nil? || value.nil?
			[error.message]
		in OptionParser::AmbiguousOption
			candidates = long_options.select { |it| it.start_with?(option) }
			["#{option} is ambiguous.", "Did you mean #{candidates.join(' or ')}?"]
		in OptionParser::InvalidOption
			suggestion = suggest(option, long_options)
			["#{option} isn’t an option.", ("Did you mean #{suggestion}?" if suggestion)]
		in OptionParser::MissingArgument
			["#{name} needs a value, as in #{name}#{switch&.arg}."]
		in OptionParser::NeedlessArgument
			["#{name} doesn’t take a value."]
		in OptionParser::InvalidArgument
			["#{name} takes a whole number, not #{value.inspect}."]
		else
			[error.message]
		end
	end

	# The message and hint for a path that matches no test files.
	private def missing_path(path)
		message = if File.exist?(path)
			"#{path} has no test files (#{DEFAULT_PATTERN})."
		else
			"#{path} doesn’t exist."
		end

		require "pathname"
		files = test_files([])
		directories = files.flat_map { |file| Pathname(file).dirname.ascend.map(&:to_s) }.uniq - ["."]
		# Lines are kept, so the suggestion can be pasted as it is.
		_, base, lines = *path.chomp("/").match(/\A(.*?)((?::\d+)*)\z/)
		suggestion = suggest(base, files + directories)
		[message, ("Did you mean #{suggestion}#{lines}?" if suggestion)]
	end

	private def suggest(input, candidates)
		require "did_you_mean"
		DidYouMean::SpellChecker.new(dictionary: candidates).correct(input).first
	end

	private def usage_error(message, hint = nil)
		warn "#{red('Error:', $stderr)} #{message}"
		warn hint if hint
		warn dim("Run #{Quickdraw::Reporters.command} --help for usage.", $stderr)
		exit 2
	end

	private def bold(text, io = $stdout) = style(text, 1, io)
	private def dim(text, io = $stdout) = style(text, 2, io)
	private def red(text, io = $stdout) = style(text, 31, io)

	HELP_WIDTH = 100

	# Descriptions wrapped to the terminal under their column, with the options
	# they describe highlighted.
	private def help_text(parser)
		column = 4 + parser.summary_width + 1
		width = [terminal_columns || HELP_WIDTH, HELP_WIDTH].min

		# Too narrow for two columns, descriptions go under what they describe.
		narrow = width - column < 30

		parser.help.lines(chomp: true).flat_map do |line|
			next [line] unless line.start_with?("    ") && line.size > column && line[column - 1] == " "

			head = line[0, column]
			option = cyan(head.rstrip) unless head.strip.empty?

			if narrow
				[*option, *wrap(line[column..], [width - 8, 20].max).map { |text| "        #{text}" }]
			else
				lines = wrap(line[column..], width - column)
				first = option ? "#{option}#{' ' * (column - head.rstrip.size)}" : head
				["#{first}#{lines.first}", *lines.drop(1).map { |text| "#{' ' * column}#{text}" }]
			end
		end.join("\n")
	end

	private def wrap(text, width)
		text.split.each_with_object([+""]) do |word, lines|
			lines << +"" if !lines.last.empty? && lines.last.size + word.size + 1 > width
			lines.last << " " unless lines.last.empty?
			lines.last << word
		end
	end

	private def terminal_columns
		require "io/console"
		$stdout.winsize[1]
	rescue LoadError, SystemCallError, NoMethodError
		nil
	end

	private def cyan(text, io = $stdout) = style(text, 36, io)

	private def style(text, code, io)
		(io.tty? && !ENV.key?("NO_COLOR")) ? "\e[#{code}m#{text}\e[0m" : text
	end

	# "test/a.test.rb:12:40" is the file with lines 12 and 40, when the file
	# exists. Anything else is a path or glob.
	private def split_lines(argument)
		if (match = /\A(?<path>.+?)(?<lines>(?::\d+)+)\z/.match(argument)) && File.file?(match[:path])
			[match[:path], *match[:lines].delete_prefix(":").split(":").map { |line| Integer(line, 10) }]
		else
			[argument]
		end
	end

	private def run(options)
		files = test_files(options[:patterns])
		# Files that run even when browser tests are left out (see Coordinator#selected?):
		# those given, and in watch mode, changed.
		named = [*options[:patterns], *options[:changed_paths]].select { |path| File.file?(path) }
		files, named = changed_test_files(files, history: options[:history], base: options[:base]) if options[:changed]
		only_keys = nil
		whole_files = {}

		if options[:failed]
			failing_tests, unloadable_files = failing

			# With no paths given, failing tests anywhere count, not just in the default pattern.
			failing_paths = (failing_tests.map(&:last) + unloadable_files).uniq

			files = if options[:patterns].empty?
				failing_paths.select { |path| File.file?(path) }
			else
				wanted = failing_paths.to_h { |path| [File.expand_path(path), true] }
				files.select { |path| wanted.key?(File.expand_path(path)) }
			end

			only_keys = failing_tests.to_h { |key, _path| [key, true] }
			whole_files = unloadable_files.to_h { |path| [path, true] }
			named = files

			# On stderr, so it can't corrupt a JSON stream.
			warn "No tests are failing in the run history." if files.empty?
		end

		# From watch mode's path filter.
		if (text = options[:path_contains])
			files = files.select { |path| path.include?(text) }
			warn "No test files have #{text} in their path." if files.empty?
		end

		# By real path, since a file reached by two paths is found by one.
		named = named.to_h { |path| [File.realpath(path), true] }
		named_files = files.select { |path| named.key?(File.realpath(path)) }.to_h { |path| [File.expand_path(path), true] }

		# Keyed by each file's expanded path, as the coordinator knows it.
		lines = files.each_with_object({}) do |path, by_path|
			by_path[File.expand_path(path)] = options[:lines][File.realpath(path)] if options[:lines].key?(File.realpath(path))
		end

		terminal = $stdout

		# Without fork, tests print in this process, so what they print goes to
		# stderr here, as loaders send it there with fork.
		if machine_readable?(options) && !Quickdraw::Platform.supports_forking?
			terminal = $stdout.dup
			terminal.sync = true
			$stdout.reopen($stderr)
		end

		reporter = reporter(options, terminal)

		Quickdraw::Coordinator.new(
			files:,
			processes: options[:processes],
			cores: options[:cores],
			max_processes: options[:max_processes],
			# inspect, so a path containing a space can't collide with two paths.
			selection: [
				*@scope,
				*options[:patterns].sort,
				*options[:lines].sort.map { |path, lines| "#{path}:#{lines.sort.join(':')}" },
				*options[:names].map { |name| "--name #{name}" },
				*options[:excludes].map { |name| "--exclude #{name}" },
				*options[:browsers].sort.map { |browser| "--browser #{browser}" },
				("--failed" if options[:failed]),
				("--changed" if options[:changed]),
				("path contains #{options[:path_contains]}" if options[:path_contains]),
				*options[:required_names]&.map { |name| "name matches #{name}" },
			].compact.inspect,
			filter: Quickdraw::Filter.new(
				lines:,
				names: options[:names].map { |name| Quickdraw::Filter::NamePattern.parse(name) },
				required_names: (options[:required_names] || []).map { |name| Quickdraw::Filter::NamePattern.parse(name) },
				excludes: options[:excludes].map { |name| Quickdraw::Filter::NamePattern.parse(name) },
			),
			fail_fast: options[:fail_fast],
			test_output_to_stderr: machine_readable?(options),
			seed: options[:seed],
			reporter:,
			history_path: (HISTORY_PATH if options[:history]),
			only_keys:,
			whole_files:,
			profile: options[:profile],
			coverage: options[:coverage],
			capture: options[:capture],
			# What loading prints goes through the reporter, so it isn't mixed into its lines.
			capture_loading: reporter.shows_loading_output?,
			leaks: options[:leaks]&.to_sym,
			retries: options[:retries],
			allow_flaky: options[:allow_flaky],
			quarantine: options[:quarantine],
			flakes_path: options[:flakes_path],
			output_paths: [*options[:outputs].filter_map(&:last), (File.expand_path(Quickdraw::Reporters::LastRun::PATH) if options[:history])].compact,
			repeatable: !options[:changed],
			warm_loaders: options[:warm_loaders],
			timeline: options[:timeline],
			elastic: options[:elastic],
			variants: (options[:browsers] if options[:browsers].any?),
			browser_tests:,
			named_files:,
		).call
	end

	# See Coordinator#selected?.
	private def browser_tests
		case @scope
		in nil then :default
		in "browser" then :only
		in "all" then :all
		end
	end

	# How to run this run's tests again, for rerun commands.
	private def run_command = [Quickdraw::Reporters.command, *@scope].join(" ")

	# Whether the terminal gets a format another program reads.
	private def machine_readable?(options)
		options[:outputs].any? { |format, path| path.nil? && MACHINE_FORMATS.include?(format) }
	end

	private def reporter(options, terminal)
		# First, so it's saved before the agent format, which points to it, finishes.
		last_run = Quickdraw::Reporters::LastRun.new(command: @command_line, rerun: run_command, backtrace: options[:backtrace]) if options[:history]

		# A status line, which what tests print would garble unless it's captured, which needs fork.
		live = options[:capture] != false && Quickdraw::Platform.supports_forking?

		reporters = options[:outputs].map do |format, path|
			io = path ? File.open(path, "w") : terminal

			case format
			in "human" then Quickdraw::Reporters::Human.new(io:, backtrace: options[:backtrace], timings: options[:timings], live:, command: run_command)
			in "agent" then Quickdraw::Reporters::Agent.new(io:, backtrace: options[:backtrace], kept: (-> { last_run.saved? } if last_run), command: run_command)
			in "json" then Quickdraw::Reporters::JSON.new(io:)
			in "junit" then Quickdraw::Reporters::JUnit.new(io:)
			end
		end

		reporters.unshift(last_run) if last_run

		# Annotations go to the terminal.
		reporters << Quickdraw::Reporters::GitHubActions.new if Quickdraw::Reporters::GitHubActions.active? && !machine_readable?(options)

		(reporters.size == 1) ? reporters.first : Quickdraw::Reporters::Multiple.new(reporters)
	end

	# Changes that could affect any test, so --changed runs them all. Gemfiles
	# anywhere, since a group can have its own.
	EVERYTHING = %r{(?:\A|/)(?:Gemfile|gems\.rb)(?:\.lock|\.locked)?\z|\.gemfile(?:\.lock)?\z|\A(?:[^/]+\.gemspec|\.ruby-version)\z}

	# For --changed: of `files`, those changed since the last commit, and those
	# whose tests ran a changed source file in the last --coverage run of them.
	# Without that map, the changed source files' counterparts. Explanations go
	# to stderr, so they can't corrupt a JSON stream. Returns them, and the test
	# files that changed themselves, which count as named.
	private def changed_test_files(files, history:, base:)
		changes = begin
			Quickdraw::Changes.files(base:) or usage_error("--changed needs a git repository, to see what’s changed.")
		rescue Quickdraw::Changes::UnknownBase => error
			usage_error(error.message)
		end
		test_paths = files.to_h { |path| [path.delete_prefix("./"), path] }
		changed_tests = changes.filter_map { |path| test_paths[path] }

		# Config, the Gemfile and test helpers, which coverage doesn't map.
		everything = changes.select do |path|
			EVERYTHING.match?(path) || path == Quickdraw::Loader::CONFIG_PATH ||
				(path.end_with?(".rb") && !test_paths.key?(path) && Quickdraw::CoverageCollector::EXCLUDED.match?(path))
		end

		if everything.any?
			warn "Running every test, since #{everything.first(3).join(', ')}#{' and more' if everything.size > 3} changed."
			return [files, changed_tests]
		end

		sources = changes.select { |path| path.end_with?(".rb") && !test_paths.key?(path) }
		covering, booted = (coverage_map(sources) if history && sources.any?) || [nil, []]

		# Loading a file can affect any test, through its constants or callbacks.
		if booted.any?
			warn "Running every test, since #{booted.first(3).join(', ')}#{' and more' if booted.size > 3} changed, which loads with config but no test runs its code."
			return [files, changed_tests]
		end

		if covering.nil? && sources.any?
			warn "No --coverage run has mapped which tests run which files, so running the changed files’ tests by name."
			counterpart = Quickdraw::Commands::Counterpart.new
			# Deleted files' tests too, since they may still use them.
			covering = sources.filter_map { |path| counterpart.find(path) }
		end

		unmapped = changes - sources - test_paths.keys
		warn "Coverage only maps Ruby, so tests that use #{unmapped.first(3).join(', ')}#{' and more' if unmapped.size > 3} may not run." if unmapped.any?

		selected = (changes + covering.to_a).filter_map { |path| test_paths[path] }.uniq
		warn "Nothing has changed that any test runs." if selected.empty?
		[selected, changed_tests]
	end

	# See History#tests_covering. Nil without history or a map. Read in a
	# throwaway process, for the same reason as #failing.
	private def coverage_map(sources)
		Quickdraw.isolate do
			next unless Quickdraw::History.exist?(HISTORY_PATH)

			history = Quickdraw::History.new(HISTORY_PATH, read_only: true)
			history.tests_covering(sources)
		rescue Quickdraw::History::Error
			nil
		ensure
			history&.close
		end
	end

	# Read in a throwaway process, since the loader forks from this one and
	# sqlite3 must not reach it.
	private def failing
		result = Quickdraw.isolate do
			next [[], []] unless Quickdraw::History.exist?(HISTORY_PATH)

			history = Quickdraw::History.new(HISTORY_PATH, read_only: true)
			[history.failing_tests, history.unloadable_files]
		rescue Quickdraw::History::Error => error
			error.message
		ensure
			history&.close
		end

		case result
		in [failing_tests, unloadable_files]
			[failing_tests, unloadable_files]
		in String => message
			abort "--failed couldn’t read the run history (#{message})."
		end
	end

	# Files are used as given, directories are searched for test files, and
	# anything else is a glob. The default skips directories that hold other
	# projects' tests, such as installed gems. A file reached by two paths is only
	# run once.
	private def test_files(patterns)
		files = if patterns.empty?
			Dir.glob(DEFAULT_PATTERN).grep_v(IGNORED_DIRECTORIES)
		else
			patterns.flat_map do |pattern|
				if File.file?(pattern)
					[pattern]
				elsif File.directory?(pattern)
					Dir.glob(DEFAULT_PATTERN, base: pattern).map { |path| File.join(pattern, path) }
				else
					Dir.glob(pattern).select { |path| File.file?(path) }
				end
			end
		end

		files.uniq { |path| File.realpath(path) }
	end

	private def watch(options)
		watch = Quickdraw::Watch.new(options, for_people: !machine_readable?(options)) { |run_options| run_in_fork(run_options) }
		exit(watch.call)
	end

	private def run_in_fork(options)
		pid = Process.fork do
			# A file given as an argument may have been deleted since the last run.
			options[:patterns].each do |pattern|
				usage_error(*missing_path(pattern)) if test_files([pattern]).empty?
			end

			exit(run(options).exit_status)
		end

		Process.wait2(pid).last
	end
end
