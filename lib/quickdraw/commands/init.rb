# frozen_string_literal: true

# Sets a project up: config, an example test when there are none, and run
# history ignored by git. Leaves anything that's already there alone.
class Quickdraw::Commands::Init
	include Quickdraw::Commands::Output

	CONFIG = <<~RUBY
		# frozen_string_literal: true

		# Loaded once before tests, then shared by every worker.

		Quickdraw.configure do |config|
			# Seconds before a test times out, or nil for never.
			# config.timeout = 300

			# Runs once, before workers start. Boot your app here.
			# config.before_forking { require_relative "../app" }

			# Runs in each worker. ENV["QUICKDRAW_WORKER"] is its number, for a database per worker.
			# config.after_forking { }
		end
	RUBY

	EXAMPLE = <<~RUBY
		# frozen_string_literal: true

		class ExampleTest < Quickdraw::Test
			test "adds numbers" do
				assert_equal 1 + 1, 2
			end

			describe "strings" do
				test "can be upcased" do
					assert_equal "hello".upcase, "HELLO"
				end
			end
		end
	RUBY

	EXAMPLE_PATH = "test/example.test.rb"
	IGNORED = ".quickdraw/"

	def initialize(args, io: $stdout)
		@args = args
		@io = io
	end

	def call
		unless @args.empty?
			warn "Usage: #{Quickdraw::Reporters.command} init"
			return 2
		end

		create(Quickdraw::Loader::CONFIG_PATH, CONFIG)

		if Dir.glob(Quickdraw::CLI::DEFAULT_PATTERN).grep_v(Quickdraw::CLI::IGNORED_DIRECTORIES).empty?
			create(EXAMPLE_PATH, EXAMPLE)
		else
			skipped("an example test", "there are tests already")
		end

		ignore_history

		@io.puts
		@io.puts "Run your tests with #{bold(Quickdraw::Reporters.command)}."
		0
	end

	private def create(path, content)
		if File.exist?(path)
			skipped(path, "it exists")
		else
			require "fileutils"
			FileUtils.mkdir_p(File.dirname(path))
			File.write(path, content)
			@io.puts "#{green('created')} #{path}"
		end
	end

	private def ignore_history
		if File.exist?(".gitignore")
			if Quickdraw::Commands.history_ignored?
				skipped(".gitignore", "it ignores #{IGNORED} already")
			else
				content = File.read(".gitignore")
				File.write(".gitignore", "#{content}#{"\n" unless content.empty? || content.end_with?("\n")}#{IGNORED}\n")
				@io.puts "#{green('updated')} .gitignore #{dim("to ignore #{IGNORED}, where run history is kept")}"
			end
		elsif File.exist?(".git")
			File.write(".gitignore", "#{IGNORED}\n")
			@io.puts "#{green('created')} .gitignore #{dim("to ignore #{IGNORED}, where run history is kept")}"
		end
	end

	private def skipped(what, reason)
		@io.puts dim("skipped #{what} (#{reason})")
	end
end
