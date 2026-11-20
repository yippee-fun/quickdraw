# frozen_string_literal: true

# Keeps each run that records history, so an agent that didn't see it can
# read it with `quickdraw last`, which replays it into the agent format, and
# ask for any problem's details. It keeps what that format needs: results
# with problems or leaks, in full, and the outcome, not every passing result.
# It's JSON, since a checkout's files are untrusted, written once the run
# finishes, through a temporary file, so it's never part of one run.
class Quickdraw::Reporters::LastRun
	PATH = ".quickdraw/last-run.json"

	# `command` is how the run was started, shown when it's read. `backtrace`
	# is whether the agent format showed whole backtraces.
	def initialize(command:, backtrace: false, path: PATH)
		@command = command
		@backtrace = backtrace
		@path = path
		@results = []
		@load_errors = []
		@saved = false
	end

	def start(processes:, worker_choice:, seed:, **)
		@start = { "processes" => processes, "worker_choice" => worker_choice, "seed" => seed }
	end

	def result(path, test, result)
		@results << [path, test, result] if result["errors"].any? || result["failures"].any? || result["leaks"]
	end

	def load_failed(path, error)
		@load_errors << [path, error]
	end

	def finished_file(_path) = nil
	def shows_loading_output? = false
	def pause = nil
	def resume = nil

	# Before other reporters finish, so the agent format knows it can point to it.
	def finish(outcome)
		require "json"
		require "fileutils"

		run = {
			"command" => @command,
			"finished_at" => Time.now.to_f,
			"backtrace" => @backtrace,
			"start" => @start,
			"results" => @results,
			"load_errors" => @load_errors,
			"outcome" => (outcome.instance_variables - [:@coverage]).to_h { |name| [name.to_s, outcome.instance_variable_get(name)] },
		}

		FileUtils.mkdir_p(File.dirname(@path))
		temporary = "#{@path}.#{Process.pid}"
		File.write(temporary, JSON.generate(utf8(run)))
		File.rename(temporary, @path)
		@saved = true
	rescue SystemCallError, JSON::GeneratorError => error
		warn "Quickdraw couldn’t write #{@path} (#{error.message})."
	end

	# Whether this run was saved, so `quickdraw last` shows it.
	def saved? = @saved

	# The last run kept in this directory, or nil.
	def self.read(path = PATH)
		require "json"
		JSON.parse(File.read(path, encoding: Encoding::UTF_8)) if File.exist?(path)
	rescue JSON::ParserError
		nil
	end

	# An Agent reporter that has seen `run`, ready to finish or show details.
	def self.replay(run, io:)
		agent = Quickdraw::Reporters::Agent.new(io:, backtrace: run["backtrace"], kept: -> { true }, replay: true)
		start = run["start"]
		agent.start(processes: start["processes"], worker_choice: start["worker_choice"], seed: start["seed"], paths: [])
		run["results"].each { |path, test, result| agent.result(path, test, result) }
		run["load_errors"].each { |path, error| agent.load_failed(path, error) }
		agent
	end

	# The run's Outcome, without coverage, which `quickdraw last` doesn't show.
	def self.outcome(run)
		Quickdraw::Outcome.new.tap do |outcome|
			run["outcome"].each do |name, value|
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
