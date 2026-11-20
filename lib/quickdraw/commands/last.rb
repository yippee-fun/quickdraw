# frozen_string_literal: true

# The last run, for an AI agent told that tests failed in a run it didn't
# see: its result with each problem on a line (see Reporters::Agent), then
# the details of whichever problems it asks for. `--from FILE` reads a run
# kept elsewhere, such as a CI artifact. See Reporters::LastRun.
class Quickdraw::Commands::Last
	include Quickdraw::Commands::Output
	include Quickdraw::Reporters::Formatting

	USAGE = "Usage: %s last [--from FILE] [PATH[:LINE] | --list]"

	def initialize(args, io: $stdout)
		@args = args
		@io = io
	end

	def call
		from = nil
		targets = []
		arguments = @args.dup

		while (argument = arguments.shift)
			case argument
			in "--from" then from = arguments.shift or return usage
			in /\A--from=./ then from = argument.delete_prefix("--from=")
			else targets << argument
			end
		end

		return usage if targets.size > 1

		begin
			run = Quickdraw::Reporters::LastRun.read(from || Quickdraw::Reporters::LastRun::PATH)
		rescue Quickdraw::Reporters::LastRun::Unreadable => error
			warn error.message
			return 1
		end

		unless run
			warn from ? "There’s no #{from}." : "No run has been recorded here. Runs with --no-history aren’t."
			return 1
		end

		start = run.start
		on = " on #{start['ruby']}" unless start["ruby"] == RUBY_DESCRIPTION

		if run.finished?
			@io.puts "Ran `#{start['command']}` #{ago(Time.now.to_f - run.finish['finished_at'])}#{on}."
		else
			found = pluralize(run.results.size + run.load_errors.size, "problem")
			@io.puts "Started `#{start['command']}` #{ago(Time.now.to_f - start['started_at'])}#{on}, and hasn’t finished: it’s still running, or was stopped or crashed, having found #{found}."
		end

		last = [Quickdraw::Reporters.command, "last", *(["--from", shell_quote(from)] if from)].join(" ")
		agent = Quickdraw::Reporters::LastRun.replay(run, io: @io, last:)

		case targets.first
		in nil if run.finished?
			outcome = Quickdraw::Reporters::LastRun.outcome(run)
			# --failed reads this checkout's history, not the one the run was kept in.
			outcome.recorded = false if from
			agent.finish(outcome)
		in nil | "--list" then agent.print_list
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
