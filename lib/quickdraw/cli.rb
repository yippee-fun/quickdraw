# frozen_string_literal: true

class Quickdraw::CLI
	DEFAULT_PATTERN = "**/*.test.rb"
	IGNORED_DIRECTORIES = %r{\A(?:vendor|node_modules|tmp)/}
	HISTORY_PATH = ".quickdraw/history.sqlite3"
	FORMATS = ["human", "agent", "json"].freeze
	MAX_SEED = (2 ** 63) - 1

	LISTENER = <<~RUBY
		require "listen"
		$stdout.sync = true
		# The default FSEvents latency adds ~100ms to every change. Quickdraw's own
		# history, and any files passed as arguments (such as JUnit output), must
		# not trigger another run.
		ignored = [%r{\\A\\.quickdraw/}, *ARGV.map { |path| /\\A\#{Regexp.escape(path)}\\z/ }]
		Listen.to(".", latency: 0.01, wait_for_delay: 0.01, ignore: ignored) { puts "changed" }.start
		sleep
	RUBY

	def initialize(args)
		@args = args
	end

	def call
		# optparse, etc and anything else needed to parse options load in a
		# throwaway process so they don’t leak into the processes that run tests.
		options = Quickdraw.isolate { parse }

		if options[:watch]
			watch(options)
		else
			exit(run(options) ? 0 : 1)
		end
	end

	private def parse
		require "optparse"

		options = {
			backtrace: false,
			timings: false,
			processes: nil,
			watch: false,
			seed: nil,
			efficiency: false,
			history: true,
			failed: false,
			fail_fast: false,
			names: [],
			excludes: [],
			format: nil,
			junit: nil,
		}

		OptionParser.new do |parser|
			parser.banner = "Usage: quickdraw [options] [paths, globs or path:line]"

			parser.on("-h", "--help", "Prints this help") do
				puts parser
				exit
			end

			parser.on("-n", "--name PATTERN", "Run tests whose name contains PATTERN, or matches /PATTERN/") do |it|
				options[:names] << it
			end

			parser.on("-x", "--exclude PATTERN", "Skip tests whose name contains PATTERN, or matches /PATTERN/") do |it|
				options[:excludes] << it
			end

			parser.on("--fail-fast", "Stop starting tests after the first failure or error") do
				options[:fail_fast] = true
			end

			parser.on("--format FORMAT", FORMATS, "Output format: #{FORMATS.join(', ')} (agent under AI coding agents, else human)") do |it|
				options[:format] = it
			end

			parser.on("--junit PATH", "Also write JUnit XML to PATH") do |it|
				options[:junit] = File.expand_path(it)
			end

			parser.on("-b", "--backtrace", "Show backtrace frames inside Quickdraw") do
				options[:backtrace] = true
			end

			parser.on("-t", "--timings", "Show the slowest tests and files") do
				options[:timings] = true
			end

			parser.on("-f", "--failed", "Run only the tests that failed in the last run") do
				options[:failed] = true
			end

			parser.on("--no-history", "Don’t read or record run history (#{HISTORY_PATH})") do
				options[:history] = false
			end

			parser.on("-p N", "--processes N", Integer, "Number of worker processes") do |it|
				options[:processes] = it
			end

			parser.on("-m", "--max", "Use all available CPU cores") do
				options[:max] = true
			end

			parser.on("-e", "--efficiency", "Use efficiency cores (Apple M-series Macs only)") do
				options[:efficiency] = true
			end

			parser.on("-w", "--watch", "Watch for changes") do
				options[:watch] = true
			end

			parser.on("-s N", "--seed N", Integer, "Seed for randomization") do |it|
				options[:seed] = it
			end
		end.parse!(@args)

		if [options[:processes], options[:max], options[:efficiency]].count(&:itself) > 1
			abort "Use only one of --processes, --max and --efficiency."
		end

		abort "--failed needs run history, so it can’t be used with --no-history." if options[:failed] && !options[:history]

		if options[:efficiency] && !Quickdraw::Platform.m_series?
			abort "Efficiency cores are only available on M-series Macs."
		end

		if options[:watch] && !Quickdraw::Platform.supports_forking?
			abort "Watch mode needs fork, which this platform doesn’t support."
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

		abort "--processes must be at least 1." if options[:processes]&.< 1

		options[:cores] = Quickdraw::Platform.supports_forking? ? Quickdraw::Platform.non_blocking_cores : 1
		# Tests that mostly wait can use more workers than cores; beyond this the
		# memory and scheduling overhead outweighs it.
		options[:max_processes] = Quickdraw::Platform.cpu_cores * 3

		options[:seed] ||= ENV["SEED"]&.then do |it|
			Integer(it, exception: false) || abort("SEED must be an integer, got #{it.inspect}.")
		end
		options[:seed] ||= Random.new_seed % 100_000

		# Seeds are stored in SQLite, whose integers are signed 64-bit.
		abort "The seed must be between 0 and #{MAX_SEED}." unless (0..MAX_SEED).cover?(options[:seed])

		options[:patterns] = []
		options[:lines] = {}

		@args.each do |argument|
			path, *lines = split_lines(argument)
			options[:patterns] << path
			(options[:lines][File.realpath(path)] ||= []).concat(lines) if lines.any?
		end

		(options[:names] + options[:excludes]).each do |pattern|
			Quickdraw::Filter::NamePattern.parse(pattern)
		rescue RegexpError => error
			abort "Invalid --name or --exclude pattern #{pattern}: #{error.message}"
		end

		options
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
			].compact.inspect,
			filter: Quickdraw::Filter.new(
				lines:,
				names: options[:names].map { |name| Quickdraw::Filter::NamePattern.parse(name) },
				excludes: options[:excludes].map { |name| Quickdraw::Filter::NamePattern.parse(name) },
			),
			fail_fast: options[:fail_fast],
			# What tests print would corrupt a JSON stream, so it goes to stderr.
			test_output_to_stderr: output_format(options) == "json",
			seed: options[:seed],
			reporter: reporter(options),
			history_path: (HISTORY_PATH if options[:history]),
			only_keys:,
			whole_files:,
		).call
	end

	private def output_format(options)
		options[:format] || (Quickdraw::Reporters.agent? ? "agent" : "human")
	end

	private def reporter(options)
		format = output_format(options)

		primary = case format
		in "human" then Quickdraw::Reporters::Human.new(backtrace: options[:backtrace], timings: options[:timings])
		in "agent" then Quickdraw::Reporters::Agent.new(backtrace: options[:backtrace])
		in "json" then Quickdraw::Reporters::JSON.new
		end

		reporters = [primary]
		# Annotations go to stdout, so they'd corrupt a JSON stream.
		reporters << Quickdraw::Reporters::GitHubActions.new if Quickdraw::Reporters::GitHubActions.active? && format != "json"
		reporters << Quickdraw::Reporters::JUnit.new(path: options[:junit]) if options[:junit]

		(reporters.size == 1) ? primary : Quickdraw::Reporters::Multiple.new(reporters)
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

	# Files are used as given; anything else is a glob, which must match
	# something. The default skips directories that hold other projects' tests,
	# such as installed gems. A file reached by two paths is only run once.
	private def test_files(patterns)
		files = if patterns.empty?
			Dir.glob(DEFAULT_PATTERN).grep_v(IGNORED_DIRECTORIES)
		else
			patterns.flat_map do |pattern|
				next [pattern] if File.file?(pattern)

				Dir.glob(pattern).tap do |matches|
					abort "No test files match #{pattern}." if matches.empty?
				end
			end
		end

		files.uniq { |path| File.realpath(path) }
	end

	private def watch(options)
		# Files Quickdraw itself writes in the project mustn't trigger another run.
		ignored = [options[:junit]].compact.filter_map do |path|
			relative = path.delete_prefix("#{Dir.pwd}/")
			relative unless relative == path
		end

		listener = IO.popen([RbConfig.ruby, "-e", LISTENER, *ignored])

		run_in_fork(options)
		listener.each_line { run_in_fork(options) }
		listener.close
		abort "The file watcher stopped (#{$?})." unless $?.success?
	ensure
		Process.kill("TERM", listener.pid) if listener && !listener.closed?
	end

	private def run_in_fork(options)
		pid = Process.fork do
			print "\e[H\e[2J" unless output_format(options) == "json"
			exit(run(options) ? 0 : 1)
		end

		Process.wait(pid)
	end
end
