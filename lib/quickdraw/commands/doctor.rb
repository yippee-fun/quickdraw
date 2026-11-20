# frozen_string_literal: true

# Checks what Quickdraw depends on, with a fix for anything wrong. Exits 1 if
# tests can't run; warnings are for features that won't work.
class Quickdraw::Commands::Doctor
	include Quickdraw::Commands::Output

	MINIMUM_RUBY = "3.3"
	# Each worker needs four file descriptors (see Coordinator#channel_capacity).
	DESCRIPTORS_PER_WORKER = 4

	BROWSER_NAMES = { "chromium" => "Chromium", "firefox" => "Firefox", "webkit" => "WebKit" }.freeze

	# `topic` is a word or two for the column on the left.
	Check = Data.define(:level, :topic, :message, :hint)

	def initialize(args, io: $stdout)
		@args = args
		@io = io
	end

	def call
		unless @args.empty?
			warn "Usage: #{Quickdraw::Reporters.command} doctor"
			return 2
		end

		# config finds config.browser's options for browsers.
		checks = [ruby, forking, cores, file_descriptors, test_files, config, *browsers, history, watching, ignored_history].compact
		width = checks.map { |check| check.topic.size }.max

		checks.each do |check|
			symbol = case check.level
			in :ok then green("✓")
			in :warning then yellow("!")
			in :problem then red("✗")
			end

			@io.puts "  #{symbol} #{dim(check.topic.ljust(width))}  #{check.message}"
			@io.puts "    #{' ' * width}  #{dim(check.hint)}" if check.hint
		end

		problems = checks.count { |check| check.level == :problem }
		warnings = checks.count { |check| check.level == :warning }
		@io.puts

		if problems > 0
			@io.puts "#{label('NOT READY', 41)} #{pluralize(problems, 'problem')} to fix before tests can run"
			1
		else
			@io.puts "#{label('READY', 42)} Tests can run#{dim(" · #{pluralize(warnings, 'warning')}") if warnings > 0}"
			0
		end
	end

	private def ruby
		if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new(MINIMUM_RUBY)
			Check.new(:ok, "Ruby", "#{RUBY_VERSION}#{' with YJIT' if yjit?}", nil)
		else
			Check.new(:problem, "Ruby", "#{RUBY_VERSION} is older than #{MINIMUM_RUBY}", "Quickdraw supports the Ruby versions that are still maintained.")
		end
	end

	private def yjit?
		defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
	end

	private def forking
		if Quickdraw::Platform.supports_forking?
			Check.new(:ok, "Parallel", "fork is available, so tests run in parallel", nil)
		else
			Check.new(:warning, "Parallel", "fork isn’t available on #{RUBY_PLATFORM}, so tests run one at a time", nil)
		end
	end

	private def cores
		return unless Quickdraw::Platform.supports_forking?

		total = Quickdraw::Platform.cpu_cores
		for_tests = Quickdraw::Platform.non_blocking_cores
		detail = Quickdraw::Platform.m_series? ? dim(" · #{Quickdraw::Platform.efficiency_cores} efficiency cores, used with --efficiency") : ""

		Check.new(:ok, "Workers", "#{total} CPU cores · #{for_tests} workers to start with, tuned from run history#{detail}", nil)
	end

	private def file_descriptors
		soft, hard = Process.getrlimit(:NOFILE)
		needed = Quickdraw::Platform.cpu_cores * 3 * DESCRIPTORS_PER_WORKER

		if soft >= needed
			Check.new(:ok, "Descriptors", "#{delimit(soft)}, enough for the most workers Quickdraw will start", nil)
		elsif hard >= needed
			Check.new(:ok, "Descriptors", "#{delimit(soft)}, which Quickdraw raises to #{delimit(needed)} for the most workers it will start", nil)
		else
			Check.new(:warning, "Descriptors", "#{delimit(hard)} at most, which limits Quickdraw to #{hard / DESCRIPTORS_PER_WORKER} workers", "Raise the limit with `ulimit -n #{needed}`.")
		end
	end

	private def test_files
		count = Dir.glob(Quickdraw::CLI::DEFAULT_PATTERN).grep_v(Quickdraw::CLI::IGNORED_DIRECTORIES).size

		if count > 0
			Check.new(:ok, "Tests", "#{pluralize(count, 'test file')} #{dim("(#{Quickdraw::CLI::DEFAULT_PATTERN})")}", nil)
		else
			Check.new(:problem, "Tests", "No test files match #{Quickdraw::CLI::DEFAULT_PATTERN}", "Run #{Quickdraw::Reporters.command} init for an example.")
		end
	end

	# Booted in a fork, as the loader does, since it's the user's code.
	private def config
		path = Quickdraw::Loader::CONFIG_PATH
		return Check.new(:ok, "Config", "No #{path}, so nothing is shared between tests", nil) unless File.exist?(path)

		result = Quickdraw.isolate do
			started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
			require File.expand_path(path)
			Quickdraw::Config.before_forking_callbacks.each(&:call)
			[Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at, Quickdraw::Browser.settings, Quickdraw::Config.settings.fetch(:browser_by_default, false)]
		rescue Exception => error
			"#{error.class}: #{error.message}"
		end

		case result
		in [Float => seconds, browser, by_default]
			@browser = browser
			@browser_by_default = by_default
			Check.new(:ok, "Config", "#{path} boots in #{Quickdraw::Timer::Duration.new(seconds * 1_000_000_000)}", nil)
		in String => error
			Check.new(:problem, "Config", "#{path} fails to boot", Quickdraw.utf8(error).lines.first.chomp)
		end
	end

	private def browsers
		return [] unless @browser

		[*readiness, selection]
	end

	# Which runs include browser tests.
	private def selection
		command = Quickdraw::Reporters.command

		if @browser_by_default
			Check.new(:ok, "Browser", "#{command} runs browser tests, as config.browser’s by_default: true says", nil)
		else
			Check.new(:ok, "Browser", "#{command} leaves browser tests out unless they’re named", "#{command} browser runs only them, and #{command} all runs everything.")
		end
	end

	# Whether config.browser's tests can run: Puma, Node, Playwright's package
	# and each browser.
	private def readiness
		# A group with a Gemfile of its own has gems this bundle doesn't.
		if @browser[:app] && !@browser[:gemfile]
			return [Check.new(:problem, "Browser", *Quickdraw::Browser::MISSING_PUMA)] if Gem.find_files("puma.rb").empty?

			require "puma/const"
			old_puma = Quickdraw::Browser.old_puma
			return [Check.new(:problem, "Browser", *old_puma)] if old_puma
		end

		playwright = Quickdraw::Browser::Executables.playwright
		return [Check.new(:problem, "Browser", "Playwright isn’t installed, for browser tests", "Run `#{Quickdraw::Reporters.command} browser install`.")] unless playwright

		version = Quickdraw::Browser::Executables.playwright_version(playwright)
		required = Quickdraw::Browser::Executables.required_node(playwright)
		node = Quickdraw::Browser::Executables.node_version

		unless node && node.to_i >= required
			return [Check.new(:problem, "Browser", "Playwright #{version} runs on Node #{required} or later, #{node ? "but this is Node #{node}" : 'which isn’t installed'}", "Install it, or set QUICKDRAW_NODE to it.")]
		end

		@browser.fetch(:browsers).map { |name| browser_installed(name.to_s, playwright:, version:, node:) }
	end

	# Whether Playwright has installed the browser `name`, one of config.browser's.
	private def browser_installed(name, playwright:, version:, node:)
		return Check.new(:problem, "Browser", "config.browser’s browser is #{name}", "It must be chromium, firefox or webkit.") unless BROWSER_NAMES.key?(name)

		install = "Run `#{Quickdraw::Reporters.command} browser install`."
		executable = Quickdraw::Browser::Remote.argument(@browser.fetch(:launch, {}))["executablePath"]

		missing = if executable
			File.executable?(executable) ? [] : [executable]
		else
			Quickdraw::Browser::Executables.missing_browsers(playwright, name, headless_shell: name == "chromium" && Quickdraw::Browser::Executables.headless_shell?(@browser))
		end

		if missing.nil?
			Check.new(:problem, "Browser", "Playwright #{version}’s installer doesn’t run, so Quickdraw can’t tell whether #{BROWSER_NAMES.fetch(name)} is installed #{dim("· #{abbreviate(playwright)}")}", install)
		elsif missing.empty?
			Check.new(:ok, "Browser", "#{BROWSER_NAMES.fetch(name)} with Playwright #{version} on Node #{node} #{dim("· #{abbreviate(playwright)}")}", nil)
		else
			Check.new(:problem, "Browser", "#{BROWSER_NAMES.fetch(name)} isn’t installed for Playwright #{version} #{dim("· #{missing.map { |path| abbreviate(path) }.join(', ')}")}", executable ? "Set config.browser’s launch: { executablePath: } to one." : install)
		end
	end

	private def abbreviate(path) = path.sub(%r{\A#{Regexp.escape(Dir.home)}(?=/)}, "~")

	private def history
		require "sqlite3"
		path = Quickdraw::CLI::HISTORY_PATH
		return Check.new(:ok, "History", "Will be kept in #{path}", nil) unless File.exist?(path)

		database = SQLite3::Database.new(path, readonly: true)
		integrity = database.get_first_value("PRAGMA quick_check")
		runs = database.get_first_value("SELECT count(*) FROM runs")
		size = File.size(path)

		if integrity == "ok"
			Check.new(:ok, "History", "#{pluralize(runs, 'run')} #{dim("· #{size / 1024}KB")}", nil)
		else
			Check.new(:warning, "History", "Damaged (#{integrity})", "It’s only a cache, so Quickdraw rebuilds it. You can also delete #{path}.")
		end
	rescue LoadError
		Check.new(:warning, "History", "sqlite3 isn’t installed, so runs aren’t recorded", "Without it there’s no worker tuning, --failed or time estimates. Add the sqlite3 gem.")
	rescue SQLite3::Exception => error
		Check.new(:warning, "History", "Can’t be read (#{error.message})", "It’s only a cache, so Quickdraw rebuilds it. You can also delete #{path}.")
	ensure
		database&.close
	end

	# Whether --watch gets file events from the OS, or has to poll for them.
	private def watching
		file_watcher = Quickdraw::Watch.start_file_watcher([])

		case file_watcher.gets
		in "ready\n" then Check.new(:ok, "Watch", "File events come from the OS, for --watch", nil)
		in String => warning then Check.new(:warning, "Watch", warning.chomp, nil)
		in nil then Check.new(:warning, "Watch", "The file watcher doesn’t start, so --watch won’t work", nil)
		end
	ensure
		Process.kill("TERM", file_watcher.pid)
		file_watcher.close
	end

	private def ignored_history
		return unless File.exist?(".git")

		unless Quickdraw::Commands.history_ignored?
			Check.new(:warning, "Git", "git doesn’t ignore .quickdraw/", "Run history is per machine. #{Quickdraw::Reporters.command} init adds it to .gitignore.")
		end
	end

	private def pluralize(count, noun)
		"#{count} #{noun}#{'s' unless count == 1}"
	end

	private def delimit(number)
		number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
	end
end
