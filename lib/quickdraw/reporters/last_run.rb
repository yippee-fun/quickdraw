# frozen_string_literal: true

# Keeps each run that records history, so an agent that didn't see it can
# read it with `quickdraw last`, which replays it into the agent format, and
# ask for any problem's details. It keeps what that format needs: results
# with problems or leaks, in full, and the outcome, not every passing result.
#
# It's JSON Lines, since a checkout's files are untrusted: a "start" event,
# with where and how the run ran, then a "result" or "load_error" event per
# problem, written as it's found, and a "finish" event with the outcome. So a
# run that's killed or crashes keeps what it found, such as for a CI artifact.
class Quickdraw::Reporters::LastRun
	include Quickdraw::Reporters::Formatting

	PATH = ".quickdraw/last-run.jsonl"
	# What's kept and how. Changed when either does, so `quickdraw last` won't
	# misread a file another version wrote.
	FORMAT = 2

	# A file `quickdraw last` can't read.
	class Unreadable < StandardError; end

	# A kept run's events. `finish` is nil if the run didn't finish.
	Run = Data.define(:start, :results, :load_errors, :finish) do
		def finished? = !finish.nil?
	end

	# `command` is how the run was started, shown when it's read, and `rerun`
	# runs its tests again, such as `qd browser`. `backtrace` is whether the
	# agent format showed whole backtraces.
	def initialize(command:, arguments: [], rerun: Quickdraw::Reporters.command, backtrace: false, path: PATH)
		@command = command
		@arguments = arguments
		@rerun = rerun
		@backtrace = backtrace
		@path = path
		@saved = false
	end

	# So a run that crashes before it starts can't be mistaken for the last one.
	def booting
		File.delete(@path)
	rescue SystemCallError
		nil
	end

	# Written to a temporary file, then moved into place, so the last run's
	# file is only replaced by one that says what this run is.
	def start(processes:, worker_choice:, seed:, **)
		require "json"
		require "fileutils"
		require_relative "../version"

		FileUtils.mkdir_p(File.dirname(@path))
		temporary = "#{@path}.#{Process.pid}"
		@file = File.open(temporary, "w")
		@file.sync = true

		write(
			"event" => "start",
			"format" => FORMAT,
			"quickdraw" => Quickdraw::VERSION,
			"ruby" => RUBY_DESCRIPTION,
			"platform" => RUBY_PLATFORM,
			# Paths in results are under these, which `quickdraw last` maps to its own.
			"directory" => Quickdraw::ROOT,
			"library" => File.dirname(Quickdraw::LIB),
			"command" => @command,
			"arguments" => @arguments,
			"rerun" => @rerun,
			"backtrace" => @backtrace,
			"started_at" => Time.now.to_f,
			"processes" => processes,
			"worker_choice" => worker_choice,
			"seed" => seed,
		)

		File.rename(temporary, @path) if @file
	rescue SystemCallError => error
		give_up(error)
	end

	def result(path, test, result)
		return unless result["errors"].any? || result["failures"].any? || result["leaks"]

		write("event" => "result", "path" => path, "test" => test, "result" => result, "rerun" => rerun_command(path, test, test["variant"]))
	end

	def load_failed(path, error, variant)
		write("event" => "load_error", "path" => path, "error" => error, "variant" => variant, "rerun" => rerun_command(path, nil, variant))
	end

	def finished_file(_path, _variant) = nil
	def shows_loading_output? = false
	def nothing_to_run(_path, _variant) = nil
	def pause = nil
	def resume = nil

	# Before other reporters finish, so the agent format knows it can point to it.
	def finish(outcome)
		write(
			"event" => "finish",
			"finished_at" => Time.now.to_f,
			"outcome" => (outcome.instance_variables - [:@coverage]).to_h { |name| [name.to_s, outcome.instance_variable_get(name)] },
		)

		@saved = !@file.nil?
		@file&.close
	end

	# Whether this run was saved, so `quickdraw last` shows it.
	def saved? = @saved

	private def write(event)
		@file&.puts(JSON.generate(utf8(event)))
	rescue SystemCallError, JSON::GeneratorError => error
		give_up(error)
	end

	private def give_up(error)
		warn "Quickdraw couldn’t write #{@path} (#{error.message})."
		@file&.close
		@file = nil
	end

	# The run kept at `path`, or nil if there's none.
	def self.read(path = PATH)
		return unless File.exist?(path)

		require "json"

		lines = begin
			File.read(path, encoding: Encoding::UTF_8).lines
		rescue SystemCallError => error
			raise Unreadable, "Couldn’t read #{path} (#{error.message})."
		end

		events = lines.each_with_index.filter_map do |line, index|
			JSON.parse(line)
		rescue JSON::ParserError
			# Only the last line can be cut short, by the run being killed as it wrote it.
			raise Unreadable, "#{path} isn’t a run Quickdraw kept." unless index == lines.size - 1 && !line.end_with?("\n")
		end

		header = events.first

		case (header.values_at("event", "format", "quickdraw") if Hash === header)
		in ["start", FORMAT, _]
			nil
		in ["start", _, version]
			raise Unreadable, "#{path} was kept by Quickdraw #{version}, which keeps runs differently. Read it with that version."
		else
			raise Unreadable, "#{path} was kept by an older Quickdraw, which keeps runs differently. Read it with that version."
		end

		start, *rest = relocate(events, header)
		by_event = rest.group_by { |event| event["event"] }

		Run.new(
			start:,
			results: by_event.fetch("result", []).map { |event| event.values_at("path", "test", "result") },
			load_errors: by_event.fetch("load_error", []).map { |event| event.values_at("path", "error", "variant") },
			finish: by_event["finish"]&.first,
		)
	end

	# A run kept elsewhere, such as on CI, with the paths of its failures and
	# backtraces under its project and Quickdraw as this machine has them, so
	# they're shortened and filtered as this machine's own are. Messages and
	# output are left as they were.
	private_class_method def self.relocate(events, start)
		moves = {
			"#{start.fetch('library')}/" => "#{File.dirname(Quickdraw::LIB)}/",
			"#{start.fetch('directory')}/" => "#{Quickdraw::ROOT}/",
		}.reject { |from, to| from == to }

		return events if moves.empty?

		move = lambda do |path|
			from, to = moves.find { |prefix, _| path.start_with?(prefix) }
			from ? "#{to}#{path.delete_prefix(from)}" : path
		end
		move_error = -> (error) { error.merge("backtrace" => error["backtrace"].map(&move)) }

		events.map do |event|
			case event["event"]
			in "start" | "finish" then event
			in "load_error" then event.merge("error" => move_error.call(event["error"]))
			in "result"
				result = event["result"]
				failures = result["failures"].map { |failure| failure.merge("path" => move.call(failure["path"])) }
				event.merge("result" => result.merge("failures" => failures, "errors" => result["errors"].map(&move_error)))
			end
		end
	end

	# An Agent reporter that has seen `run`, ready to finish or show details.
	# `last` is the command that read it.
	def self.replay(run, io:, last:)
		start = run.start
		agent = Quickdraw::Reporters::Agent.new(io:, backtrace: start["backtrace"], kept: -> { true }, replay: true, command: start["rerun"], last:)
		agent.start(processes: start["processes"], worker_choice: start["worker_choice"], seed: start["seed"], paths: [])
		run.results.each { |path, test, result| agent.result(path, test, result) }
		run.load_errors.each { |path, error, variant| agent.load_failed(path, error, variant) }
		agent
	end

	# The finished run's Outcome, without coverage, which `quickdraw last` doesn't show.
	def self.outcome(run)
		Quickdraw::Outcome.new.tap do |outcome|
			run.finish.fetch("outcome").each do |name, value|
				outcome.instance_variable_set(name, value) if outcome.instance_variable_defined?(name) || OUTCOME_SETTINGS.include?(name)
			end
		end
	end

	# Outcome's attributes that are set as the run goes, rather than in #initialize.
	OUTCOME_SETTINGS = ["@duration", "@recorded", "@files", "@unfinished_files", "@workers_added", "@worker_time"].freeze

	# Descriptions, messages and output can be any encoding, or invalid.
	private def utf8(value)
		case value
		in String then Quickdraw.utf8(value)
		in Array then value.map { |item| utf8(item) }
		in Hash then value.to_h { |key, item| [utf8(key), utf8(item)] }
		else value
		end
	end
end
