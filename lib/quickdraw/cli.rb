# frozen_string_literal: true

class Quickdraw::CLI
	DEFAULT_PATTERN = "**/*.test.rb"
	IGNORED_DIRECTORIES = %r{\A(?:vendor|node_modules|tmp)/}
	HISTORY_PATH = ".quickdraw/history.sqlite3"
	FORMATS = ["human", "agent", "json", "junit"].freeze
	# Formats that other programs read, which what tests print would corrupt.
	MACHINE_FORMATS = ["json", "junit"].freeze
	PROFILE_TIMESLICE = "1"
	MAX_SEED = (2 ** 63) - 1

	def initialize(args)
		@args = args
	end

	def call
		# A file or directory with a command's name is still run as tests.
		if (name = @args.first) && !File.exist?(name) && (command = Quickdraw::Commands.find(name))
			exit(command.new(@args.drop(1)).call)
		end

		# optparse, etc and anything else needed to parse options load in a
		# throwaway process so they don’t leak into the processes that run tests.
		options = Quickdraw.isolate { parse }

		# Ruby reads the timeslice at boot, so it's set by starting again. See Sampler.
		if options[:profile] && ENV["RUBY_THREAD_TIMESLICE"] != PROFILE_TIMESLICE
			exec({ "RUBY_THREAD_TIMESLICE" => PROFILE_TIMESLICE }, RbConfig.ruby, "-I", Quickdraw::LIB, File.expand_path($PROGRAM_NAME), *@args)
		end

		# Forks keep the timeslice; processes that tests start shouldn't get it.
		ENV.delete("RUBY_THREAD_TIMESLICE") if options[:profile]

		if options[:watch]
			watch(options)
		else
			exit(run(options).exit_status)
		end
	end

	private def parse
		require "optparse"

		options = {
			backtrace: false,
			timings: false,
			profile: false,
			processes: nil,
			watch: false,
			seed: nil,
			efficiency: false,
			history: true,
			failed: false,
			fail_fast: false,
			names: [],
			excludes: [],
			outputs: [],
		}

		parser = option_parser(options)

		begin
			parser.parse!(@args)
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

		paths = options[:outputs].filter_map(&:last)
		if (duplicate = paths.find { |path| paths.count(path) > 1 })
			usage_error "More than one format would write to #{duplicate}."
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

		if options[:efficiency] && !Quickdraw::Platform.m_series?
			usage_error "Efficiency cores are only available on M-series Macs."
		end

		if options[:watch] && !Quickdraw::Platform.supports_forking?
			usage_error "Watch mode needs fork, which this platform doesn’t support."
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

		usage_error "--processes must be at least 1." if options[:processes]&.< 1

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

		@args.each do |argument|
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
			parser.banner = "#{bold('Usage:')} #{Quickdraw::Reporters.command} [options] [files, directories, globs or file:line …]\n       #{Quickdraw::Reporters.command} COMMAND [arguments]"
			parser.summary_width = 24
			parser.separator ""
			parser.separator "Runs tests across every core. With no paths, runs #{DEFAULT_PATTERN}."

			parser.separator ""
			parser.separator bold("Choosing tests")

			parser.on("-n", "--name PATTERN", "Only tests whose name contains PATTERN, or matches /PATTERN/flags") do |it|
				options[:names] << it
			end

			parser.on("-x", "--exclude PATTERN", "Leave out tests whose name contains PATTERN, or matches /PATTERN/flags") do |it|
				options[:excludes] << it
			end

			parser.on("-f", "--failed", "Only the tests that failed or errored in the last run") do
				options[:failed] = true
			end

			parser.on("--fail-fast", "Stop starting tests after the first failure or error") do
				options[:fail_fast] = true
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

			parser.on("--profile", "Sample tests and list the methods that take the most of their time") do
				options[:profile] = true
			end

			parser.on("-b", "--backtrace", "Include Quickdraw’s own frames in backtraces") do
				options[:backtrace] = true
			end

			parser.separator ""
			parser.separator bold("Workers")

			parser.on("-p N", "--processes N", Integer, "Run N workers (default: tuned from run history)") do |it|
				options[:processes] = it
			end

			parser.on("-m", "--max", "One worker per CPU core") do
				options[:max] = true
			end

			parser.on("-e", "--efficiency", "Run on efficiency cores (Apple silicon)") do
				options[:efficiency] = true
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
				puts parser
				exit
			end

			command = Quickdraw::Reporters.command
			examples = [
				["#{command} test/models", "Every test in a directory"],
				["#{command} test/user.test.rb:12", "The test at line 12"],
				["#{command} -n /admin/i --fail-fast", "Tests matching a regex, stopping at the first failure"],
				["#{command} --failed", "What failed last time"],
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
		system("taskpolicy", "-b", "-p", Process.pid.to_s) if options[:efficiency]

		files = test_files(options[:patterns])
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

			# On stderr, so it can't corrupt a JSON stream.
			warn "No tests are failing in the run history." if files.empty?
		end

		# From watch mode's path filter.
		if (text = options[:path_contains])
			files = files.select { |path| path.include?(text) }
			warn "No test files have #{text} in their path." if files.empty?
		end

		# Keyed by each file's expanded path, as the coordinator knows it.
		lines = files.each_with_object({}) do |path, by_path|
			by_path[File.expand_path(path)] = options[:lines][File.realpath(path)] if options[:lines].key?(File.realpath(path))
		end

		Quickdraw::Coordinator.new(
			files:,
			processes: options[:processes],
			cores: options[:cores],
			max_processes: options[:max_processes],
			# inspect, so a path containing a space can't collide with two paths.
			selection: [
				*options[:patterns].sort,
				*options[:lines].sort.map { |path, lines| "#{path}:#{lines.sort.join(':')}" },
				*options[:names].map { |name| "--name #{name}" },
				*options[:excludes].map { |name| "--exclude #{name}" },
				("--failed" if options[:failed]),
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
			reporter: reporter(options),
			history_path: (HISTORY_PATH if options[:history]),
			only_keys:,
			whole_files:,
			profile: options[:profile],
		).call
	end

	# Whether the terminal gets a format another program reads.
	private def machine_readable?(options)
		options[:outputs].any? { |format, path| path.nil? && MACHINE_FORMATS.include?(format) }
	end

	private def reporter(options)
		reporters = options[:outputs].map do |format, path|
			io = path ? File.open(path, "w") : $stdout

			case format
			in "human" then Quickdraw::Reporters::Human.new(io:, backtrace: options[:backtrace], timings: options[:timings])
			in "agent" then Quickdraw::Reporters::Agent.new(io:, backtrace: options[:backtrace])
			in "json" then Quickdraw::Reporters::JSON.new(io:)
			in "junit" then Quickdraw::Reporters::JUnit.new(io:)
			end
		end

		# Annotations go to the terminal.
		reporters << Quickdraw::Reporters::GitHubActions.new if Quickdraw::Reporters::GitHubActions.active? && !machine_readable?(options)

		(reporters.size == 1) ? reporters.first : Quickdraw::Reporters::Multiple.new(reporters)
	end

	# Read in a throwaway process, since the loader forks from this one and
	# sqlite3 must not reach it.
	private def failing
		result = Quickdraw.isolate do
			history = Quickdraw::History.new(HISTORY_PATH)
			[history.failing_tests, history.unloadable_files]
		rescue Quickdraw::History::Error => error
			error.message
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
