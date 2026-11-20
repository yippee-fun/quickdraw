# frozen_string_literal: true

# Runs tests, then again whenever files change: a changed test file on its own,
# a changed source file's tests (see Commands::Counterpart), or everything
# selected when a change has no tests of its own. On a terminal, keys rerun,
# run only failures, or filter by path or name. Loaders stay booted between
# runs (see WarmLoaders).
#
# Tests run in forks of this process, so it uses only core Ruby. File events
# come from a separate process (see FileWatcher), and keys are read with the
# terminal set by `stty`.
class Quickdraw::Watch
	# What running tests writes, such as logs and SQLite databases with their
	# journals, which would otherwise start another run, and so on forever.
	WRITTEN_BY_TESTS = %r{\A(?:log|storage)/|\.log\z|\.sqlite3}

	FILE_WATCHER = "module Quickdraw; end; require ARGV.shift; Quickdraw::FileWatcher.run(ARGV)"

	# Starts FileWatcher on `directory`, which reports changes on the IO
	# returned, ignoring `ignored` (paths relative to `directory`). It runs
	# outside the bundle, since Fiddle is a bundled gem from Ruby 4, which
	# Bundler only lets a process load if the Gemfile has it. In its own process
	# group, so Ctrl-C in a debugger doesn't stop it.
	def self.start_file_watcher(ignored, directory: Dir.pwd, poll: false)
		environment = ENV.select { |name, _| name.start_with?("BUNDLER_ORIG_") }.to_h do |name, value|
			[name.delete_prefix("BUNDLER_ORIG_"), (value unless value == "BUNDLER_ENVIRONMENT_PRESERVER_INTENTIONALLY_NIL")]
		end

		environment["QUICKDRAW_POLL"] = "1" if poll
		IO.popen([environment, RbConfig.ruby, "-e", FILE_WATCHER, File.join(__dir__, "file_watcher.rb"), *ignored], chdir: directory, pgroup: true)
	end

	KEYS = "Enter rerun · a all · f failed · p path · n name · q quit"

	def initialize(options, for_people:, &run)
		@options = options
		@for_people = for_people
		@interactive = for_people && $stdin.tty?
		# Messages go to stderr when stdout is a report another program reads.
		@out = for_people ? $stdout : $stderr
		@run = run
		@failed_only = false
		@path_filter = nil
		@name_filter = nil
	end

	# Returns the exit status: 0 when quit, otherwise the watcher's failure.
	def call
		@file_watcher = self.class.start_file_watcher(ignored_paths)
		@wake_reader, wake_writer = IO.pipe
		previous_handler = trap("INT") { wake_writer.write_nonblock("q", exception: false) unless Quickdraw::Debugger.active? }
		@terminal = take_keyboard if @interactive
		@loaders = Quickdraw::WarmLoaders.new(coverage: @options[:coverage], test_output_to_stderr: !@for_people)

		run
		watch
	ensure
		trap("INT", previous_handler || "DEFAULT") if @wake_reader
		release_keyboard
		Process.kill("TERM", @file_watcher.pid) if @file_watcher && !@file_watcher.closed?
		@loaders&.stop
	end

	private def watch
		loop do
			readable, = IO.select([@file_watcher, @wake_reader, (@interactive ? $stdin : nil)].compact)

			return 0 if readable.include?(@wake_reader)

			if readable.include?(@file_watcher)
				line = @file_watcher.gets

				unless line
					@file_watcher.close
					warn "The file watcher stopped (#{$?})."
					return 1
				end

				changed(line)
			end

			return 0 if readable.include?($stdin) && key($stdin.read_nonblock(16, exception: false)) == :quit
		end
	end

	# The file watcher batches changes that arrive together, and batches that
	# came during the last run make one run too.
	private def changed(line)
		paths = line.chomp.split("\0")
		paths.concat(@file_watcher.gets.chomp.split("\0")) while @file_watcher.wait_readable(0)
		# What the default selection leaves out, such as installed gems, never runs.
		paths = paths.uniq.grep_v(Quickdraw::CLI::IGNORED_DIRECTORIES).grep_v(WRITTEN_BY_TESTS)
		return if paths.empty?

		run(affected_tests(paths), changed: paths)
	end

	# The test files that cover the changed paths, or nil to run everything
	# selected. Only without paths given, since those choose the tests.
	private def affected_tests(paths)
		return if @options[:patterns].any? || @failed_only
		return if paths.any? { |path| !File.exist?(path) }

		counterpart = Quickdraw::Commands::Counterpart.new
		tests = paths.map { |path| path.end_with?(Quickdraw::Commands::Counterpart::TEST_SUFFIX) ? path : counterpart.find(path) }
		tests.uniq unless tests.include?(nil)
	end

	private def key(input)
		case input
		in "\r" | "\n" then run
		in "a"
			@failed_only = false
			@path_filter = nil
			@name_filter = nil
			run
		in "f" if !@options[:history]
			@out.puts "Running only failures needs run history, which --no-history turned off."
			status_line
		in "f"
			@failed_only = true
			run
		in "p"
			filter_by_path(prompt("Run test files whose path contains"))
		in "n"
			filter_by_name(prompt("Run tests whose name contains, or matches /regex/"))
		in "q" | "\u0004" then :quit
		else nil
		end
	end

	private def filter_by_path(text)
		return text if text == :quit
		return status_line unless text

		@path_filter = text
		run
	end

	private def filter_by_name(text)
		return text if text == :quit
		return status_line unless text

		Quickdraw::Filter::NamePattern.parse(text)
		@name_filter = text
		run
	rescue RegexpError => error
		@out.puts "#{text} isn’t a valid pattern: #{error.message}"
		status_line
	end

	# Filters narrow what was asked for on the command line. `changed` paths
	# may mean loaders have to boot again (see WarmLoaders#prepare).
	private def run(tests = nil, changed: [])
		# Interrupted, which #watch then sees.
		return unless @loaders.prepare(changed, interrupt: @wake_reader)

		options = @options.merge(
			failed: @options[:failed] || @failed_only,
			path_contains: @path_filter,
			required_names: [@name_filter].compact,
			warm_loaders: @loaders,
		)

		if tests
			options[:patterns] = tests
			options[:lines] = {}
		end

		@out.print "\e[H\e[2J" if @for_people
		@out.puts dim("Changed #{changed.join(', ')}, so running #{tests.join(', ')}") if tests
		@run.call(options)
		@loaders.warm_up
		status_line
	end

	# Not until the file watcher is ready, which it gets while the first run
	# happens, so "Watching" is true. Its warnings come first.
	private def status_line
		until @file_watcher_ready
			line = @file_watcher.gets
			raise "The file watcher didn’t start." unless line

			@file_watcher_ready = line == "ready\n"
			@out.puts line unless @file_watcher_ready
		end

		filters = [
			("failed" if @failed_only),
			("path contains #{@path_filter}" if @path_filter),
			("name matches #{@name_filter}" if @name_filter),
		].compact

		@out.puts
		@out.puts dim(["Watching#{" (#{filters.join(', ')})" if filters.any?}", (KEYS if @interactive)].compact.join(" · "))
	end

	# Reads one line, with the terminal back to normal while typing. Returns
	# :quit if Ctrl-C is pressed meanwhile.
	private def prompt(label)
		release_keyboard
		@out.print "#{label}: "
		readable, = IO.select([$stdin, @wake_reader])
		return :quit if readable.include?(@wake_reader)

		line = $stdin.gets&.chomp
		@terminal = take_keyboard
		line unless line.nil? || line.empty?
	end

	# Each key arrives as it's pressed, without echoing. Returns the settings to restore.
	private def take_keyboard
		settings = IO.popen(["stty", "-g"], &:read).chomp
		system("stty", "-icanon", "-echo", "min", "1")
		settings
	end

	private def release_keyboard
		system("stty", @terminal) if @terminal
		@terminal = nil
	end

	private def ignored_paths
		@options[:outputs].filter_map(&:last).filter_map do |path|
			relative = path.delete_prefix("#{Dir.pwd}/")
			relative unless relative == path
		end
	end

	private def dim(text)
		(@for_people && @out.tty? && !ENV.key?("NO_COLOR")) ? "\e[2m#{text}\e[0m" : text
	end
end
