# frozen_string_literal: true

# The last run's results, as the agent format reports them (see
# Reporters::LastRun), for an AI agent told that tests failed in a run it
# didn't see.
class Quickdraw::Commands::Last
	include Quickdraw::Commands::Output

	def initialize(args, io: $stdout)
		@args = args
		@io = io
	end

	def call
		unless @args.empty?
			warn "Usage: #{Quickdraw::Reporters.command} last"
			return 2
		end

		path = Quickdraw::Reporters::LastRun::PATH

		unless File.exist?(path)
			warn "No run has been recorded here. Runs with --no-history aren’t."
			return 1
		end

		command, report = File.read(path, encoding: Encoding::UTF_8).split("\n", 2)
		@io.puts "#{command} #{ago(Time.now - File.mtime(path))}."
		@io.print report
		0
	end
end
