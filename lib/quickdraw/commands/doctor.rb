# frozen_string_literal: true

# Checks what Quickdraw depends on, with a fix for anything wrong. Exits 1 if
# tests can't run; warnings are for features that won't work.
class Quickdraw::Commands::Doctor
	include Quickdraw::Commands::Output

	MINIMUM_RUBY = "3.3"
	# Each worker needs four file descriptors (see Coordinator#channel_capacity).
	DESCRIPTORS_PER_WORKER = 4

	Check = Data.define(:level, :message, :hint)

	def initialize(args, io: $stdout)
		@args = args
		@io = io
	end

	def call
		unless @args.empty?
			warn "Usage: #{Quickdraw::Reporters.command} doctor"
			return 2
		end

		checks = [ruby, forking, cores, file_descriptors, test_files, config, history, watching, ignored_history].compact

		checks.each do |check|
			symbol = case check.level
			in :ok then green("✓")
			in :warning then yellow("!")
			in :problem then red("✗")
			end

			@io.puts "#{symbol} #{check.message}"
			@io.puts "  #{dim(check.hint)}" if check.hint
		end

		(checks.any? { |check| check.level == :problem }) ? 1 : 0
	end

	private def ruby
		if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new(MINIMUM_RUBY)
			Check.new(:ok, "Ruby #{RUBY_VERSION}#{' with YJIT' if yjit?}", nil)
		else
			Check.new(:problem, "Ruby #{RUBY_VERSION} is older than #{MINIMUM_RUBY}", "Quickdraw supports the Ruby versions that are still maintained.")
		end
	end

	private def yjit?
		defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
	end

	private def forking
		if Quickdraw::Platform.supports_forking?
			Check.new(:ok, "fork is available, so tests run in parallel", nil)
		else
			Check.new(:warning, "fork isn’t available on #{RUBY_PLATFORM}, so tests run one at a time", nil)
		end
	end

	private def cores
		return unless Quickdraw::Platform.supports_forking?

		total = Quickdraw::Platform.cpu_cores
		for_tests = Quickdraw::Platform.non_blocking_cores
		detail = Quickdraw::Platform.m_series? ? " (#{Quickdraw::Platform.efficiency_cores} efficiency cores, used with --efficiency)" : ""

		Check.new(:ok, "#{total} CPU cores; #{for_tests} workers to start with, tuned from run history#{detail}", nil)
	end

	private def file_descriptors
		soft, hard = Process.getrlimit(:NOFILE)
		needed = Quickdraw::Platform.cpu_cores * 3 * DESCRIPTORS_PER_WORKER

		if soft >= needed
			Check.new(:ok, "#{soft} file descriptors, enough for the most workers Quickdraw will start", nil)
		elsif hard >= needed
			Check.new(:ok, "#{soft} file descriptors; Quickdraw raises this to #{needed} for the most workers it will start", nil)
		else
			Check.new(:warning, "#{hard} file descriptors limits Quickdraw to #{hard / DESCRIPTORS_PER_WORKER} workers", "Raise the limit with `ulimit -n #{needed}`.")
		end
	end

	private def test_files
		count = Dir.glob(Quickdraw::CLI::DEFAULT_PATTERN).grep_v(Quickdraw::CLI::IGNORED_DIRECTORIES).size

		if count > 0
			Check.new(:ok, "#{count} test #{(count == 1) ? 'file' : 'files'} (#{Quickdraw::CLI::DEFAULT_PATTERN})", nil)
		else
			Check.new(:problem, "No test files match #{Quickdraw::CLI::DEFAULT_PATTERN}", "Run #{Quickdraw::Reporters.command} init for an example.")
		end
	end

	# Booted in a fork, as the loader does, since it's the user's code.
	private def config
		path = Quickdraw::Loader::CONFIG_PATH
		return Check.new(:ok, "No #{path}, so nothing is shared between tests", nil) unless File.exist?(path)

		result = Quickdraw.isolate do
			started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
			require File.expand_path(path)
			Quickdraw::Config.before_forking_callbacks.each(&:call)
			Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
		rescue Exception => error
			"#{error.class}: #{error.message}"
		end

		case result
		in Float => seconds
			Check.new(:ok, "#{path} boots in #{Quickdraw::Timer::Duration.new(seconds * 1_000_000_000)}", nil)
		in String => error
			Check.new(:problem, "#{path} fails to boot", Quickdraw.utf8(error).lines.first.chomp)
		end
	end

	private def history
		require "sqlite3"
		path = Quickdraw::CLI::HISTORY_PATH
		return Check.new(:ok, "Run history will be kept in #{path}", nil) unless File.exist?(path)

		database = SQLite3::Database.new(path, readonly: true)
		integrity = database.get_first_value("PRAGMA quick_check")
		runs = database.get_first_value("SELECT count(*) FROM runs")
		size = File.size(path)

		if integrity == "ok"
			Check.new(:ok, "Run history has #{runs} runs (#{size / 1024}KB)", nil)
		else
			Check.new(:warning, "Run history is damaged (#{integrity})", "It’s only a cache, so Quickdraw rebuilds it. You can also delete #{path}.")
		end
	rescue LoadError
		Check.new(:warning, "sqlite3 isn’t installed, so runs aren’t recorded", "Without it there’s no worker tuning, --failed or time estimates. Add the sqlite3 gem.")
	rescue SQLite3::Exception => error
		Check.new(:warning, "Run history can’t be read (#{error.message})", "It’s only a cache, so Quickdraw rebuilds it. You can also delete #{path}.")
	ensure
		database&.close
	end

	private def watching
		require "listen"
		Check.new(:ok, "listen is installed, for --watch", nil)
	rescue LoadError
		Check.new(:warning, "listen isn’t installed, so --watch won’t work", "Add the listen gem.")
	end

	private def ignored_history
		return unless File.exist?(".git")

		unless Quickdraw::Commands.history_ignored?
			Check.new(:warning, "git doesn’t ignore .quickdraw/", "Run history is per machine. #{Quickdraw::Reporters.command} init adds it to .gitignore.")
		end
	end
end
