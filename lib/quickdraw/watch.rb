# frozen_string_literal: true

# Runs tests, then again whenever files change: a changed test file on its own,
# a changed source file's tests (see Commands::Counterpart), or everything
# selected when a change has no tests of its own. On a terminal, keys rerun,
# run only failures, or filter by path or name.
#
# Tests run in forks of this process, so it uses only core Ruby. File events
# come from a separate process running listen, and keys are read with the
# terminal set by `stty`.
class Quickdraw::Watch
	# Prints "ready", then each batch of changed paths on a line, separated by
	# NUL. Events are queued until then, so "ready" always comes first. The
	# default FSEvents latency adds ~100ms to every change. Quickdraw's own
	# history, and the files it writes reports to, mustn't trigger another run.
	LISTENER = <<~RUBY
		require "listen"
		$stdout.sync = true
		ignored = [%r{\\A\\.quickdraw/}, *ARGV.map { |path| /\\A\#{Regexp.escape(path)}\\z/ }]
		root = "\#{Dir.pwd}/"
		changes = Queue.new

		Listen.to(".", latency: 0.01, wait_for_delay: 0.01, ignore: ignored) do |modified, added, removed|
			changes << (modified + added + removed)
		end.start

		# Starting returns before macOS delivers events.
		sleep 0.1
		puts "ready"

		loop { puts changes.pop.map { |path| path.delete_prefix(root) }.join("\\0") }
	RUBY

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
		@listener = IO.popen([RbConfig.ruby, "-e", LISTENER, *ignored_paths])
		@wake_reader, wake_writer = IO.pipe
		previous_handler = trap("INT") { wake_writer.write_nonblock("q", exception: false) }
		@terminal = take_keyboard if @interactive

		run
		watch
	ensure
		trap("INT", previous_handler || "DEFAULT") if @wake_reader
		release_keyboard
		Process.kill("TERM", @listener.pid) if @listener && !@listener.closed?
	end

	private def watch
		loop do
			readable, = IO.select([@listener, @wake_reader, (@interactive ? $stdin : nil)].compact)

			return 0 if readable.include?(@wake_reader)

			if readable.include?(@listener)
				line = @listener.gets

				unless line
					@listener.close
					warn "The file watcher stopped (#{$?})."
					return 1
				end

				changed(line)
			end

			return 0 if readable.include?($stdin) && key($stdin.read_nonblock(16, exception: false)) == :quit
		end
	end

	# Changes arriving together, from a save that writes several files, say, make one run.
	private def changed(line)
		paths = line.chomp.split("\0")
		paths.concat(@listener.gets.chomp.split("\0")) while @listener.wait_readable(0.05)
		# What the default selection leaves out, such as installed gems, never runs.
		paths = paths.uniq.grep_v(Quickdraw::CLI::IGNORED_DIRECTORIES)
		return if paths.empty?

		affected = affected_tests(paths)
		affected ? run(affected, because: paths) : run
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

	# Filters narrow what was asked for on the command line.
	private def run(tests = nil, because: nil)
		options = @options.merge(
			failed: @options[:failed] || @failed_only,
			path_contains: @path_filter,
			required_names: [@name_filter].compact,
		)

		if tests
			options[:patterns] = tests
			options[:lines] = {}
		end

		@out.print "\e[H\e[2J" if @for_people
		@out.puts dim("Changed #{because.join(', ')}, so running #{tests.join(', ')}") if because
		@run.call(options)
		status_line
	end

	# Not until the listener is ready, which it gets while the first run happens,
	# so "Watching" is true.
	private def status_line
		unless @listening
			line = @listener.gets
			raise "The file watcher didn’t start (#{line.inspect})." unless line == "ready\n"

			@listening = true
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
