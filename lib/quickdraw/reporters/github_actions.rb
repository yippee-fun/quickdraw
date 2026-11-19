# frozen_string_literal: true

# Under GitHub Actions: an error annotation on the failing line for each
# problem, shown on the pull request's diff, and a summary on the job's page.
class Quickdraw::Reporters::GitHubActions
	include Quickdraw::Reporters::Formatting

	ANNOTATION_LIMIT = 50

	def self.active? = ENV["GITHUB_ACTIONS"] == "true"

	def initialize(io: $stdout, summary_path: ENV["GITHUB_STEP_SUMMARY"])
		@io = io
		@summary_path = summary_path
		@problems = []
	end

	def start(processes:, worker_choice:, seed:)
		@seed = seed
	end

	def result(path, test, result)
		@problems << [path, test, result] if result["errors"].any? || result["failures"].any?
	end

	def load_failed(path, error)
		@problems << [path, nil, { "errors" => [error], "failures" => [] }]
	end

	def finish(outcome)
		@problems.first(ANNOTATION_LIMIT).each { |problem| annotate(*problem) }
		write_summary(outcome) if @summary_path && !@summary_path.empty?
	end

	private def annotate(path, test, result)
		file, line = location(path, test, result)
		title = test ? name_of(test) : "#{path} could not be loaded"
		@io.puts "::error file=#{property(file)},line=#{line},title=#{property(title)}::#{data(message(result))}"
	end

	# Where the problem is: the failing assertion, or the first user frame of an
	# error, falling back to the test's own line.
	private def location(path, test, result)
		if (failure = result["failures"].first)
			[relative(failure["path"]), failure["line"]]
		elsif (frame = user_backtrace(result["errors"].first["backtrace"]).first) && (frame_path, line = frame_location(frame))
			[relative(frame_path), line]
		else
			[path, test ? test["line"] : 1]
		end
	end

	private def message(result)
		if (failure = result["failures"].first)
			plain(failure["message"]).strip
		else
			error = result["errors"].first
			"#{error['name']}: #{plain(error['message'])}"
		end
	end

	private def write_summary(outcome)
		lines = []
		lines << "### #{outcome.passed? ? '✅ Tests passed' : '❌ Tests failed'}"
		lines << ""
		lines << "| Tests | Passed | Failed | Errored | Not run | Time |"
		lines << "|---|---|---|---|---|---|"
		lines << "| #{outcome.tests} | #{outcome.passed} | #{outcome.failed} | #{outcome.errored + outcome.load_errors} | #{outcome.not_run} | #{format('%.2f', outcome.duration)}s |"

		if @problems.any?
			lines << ""
			@problems.each do |path, test, _result|
				lines << "- `#{test ? "#{path}:#{test['line']}" : path}` #{test ? name_of(test) : 'could not be loaded'}"
			end
		end

		lines << ""
		lines << "Seed #{@seed}"

		File.write(@summary_path, "#{lines.join("\n")}\n", mode: "a")
	end

	# Workflow command escaping, from GitHub's toolkit.
	private def data(text)
		text.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
	end

	private def property(text)
		data(text).gsub(":", "%3A").gsub(",", "%2C")
	end
end
