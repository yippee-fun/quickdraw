# frozen_string_literal: true

# The last run, for an AI agent told that tests failed in a run it didn't
# see: its result with each problem on a line (see Reporters::Agent), then
# the details of whichever problems it asks for. See Reporters::LastRun.
class Quickdraw::Commands::Last
	include Quickdraw::Commands::Output
	include Quickdraw::Reporters::Formatting

	USAGE = "Usage: %s last [PATH[:LINE] | --list]"

	def initialize(args, io: $stdout)
		@args = args
		@io = io
	end

	def call
		return usage if @args.size > 1

		run = Quickdraw::Reporters::LastRun.read

		unless run
			warn "No run has been recorded here. Runs with --no-history aren’t."
			return 1
		end

		@io.puts "Ran `#{run['command']}` #{ago(Time.now.to_f - run['finished_at'])}."
		agent = Quickdraw::Reporters::LastRun.replay(run, io: @io)

		case @args.first
		in nil then agent.finish(Quickdraw::Reporters::LastRun.outcome(run))
		in "--list" then agent.print_list
		in /\A-/ then return usage
		in target
			match = target.match(/\A(.+?)(?::(\d+))?\z/) or return usage
			path, line = match.captures

			if agent.print_details(relative(File.expand_path(path)), line&.to_i) == 0
				warn "The last run had no problem at #{target}."
				return 1
			end
		end

		0
	end

	private def usage
		warn format(USAGE, Quickdraw::Reporters.command)
		2
	end
end
