# frozen_string_literal: true

# Under GitHub Actions: an error annotation on the failing line for each
# problem, shown on the pull request's diff, and a summary on the job's page.
class Quickdraw::Reporters::GitHubActions
	include Quickdraw::Reporters::Formatting

	ANNOTATION_LIMIT = 50
	# GitHub shows at most 10 warnings per step.
	LEAK_LIMIT = 10

	def self.active? = ENV["GITHUB_ACTIONS"] == "true"

	def initialize(io: $stdout, summary_path: ENV["GITHUB_STEP_SUMMARY"])
		@io = io
		@summary_path = summary_path
		@problems = []
		@leaks = []
	end

	def start(processes:, worker_choice:, seed:, paths:, estimate: nil)
		@seed = seed
	end

	def result(path, test, result)
		@problems << [path, test, result] if result["errors"].any? || result["failures"].any?
		@leaks << [path, test, result["leaks"]] if result["leaks"]
	end

	def load_failed(path, error)
		@problems << [path, nil, { "errors" => [error], "failures" => [] }]
	end

	def finished_file(_path) = nil
	def shows_loading_output? = false
	def booting = nil
	def nothing_to_run(_path) = nil
	def pause = nil
	def resume = nil

	def finish(outcome)
		@problems.first(ANNOTATION_LIMIT).each { |problem| annotate(*problem) }

		@leaks.first(LEAK_LIMIT).each do |path, test, leaks|
			message = leaks.map { |leak| leak["message"] }.join("\n")
			@io.puts "::warning file=#{property(path)},line=#{test['line']},title=#{property("#{name_of(test)} left state behind")}::#{data(message)}"
		end

		write_summary(outcome) if @summary_path && !@summary_path.empty?
	end

	private def annotate(path, test, result)
		file, line = location(path, test, result)
		title = test ? name_of(test) : "#{path} could not be loaded"

		if result["quarantined"]
			@io.puts "::warning file=#{property(file)},line=#{line},title=#{property("#{title} (quarantined)")}::#{data("#{message(result)}\n\n#{QUARANTINED}")}"
		elsif result["passed_on_retry"]
			@io.puts "::warning file=#{property(file)},line=#{line},title=#{property("#{title} (flaky)")}::#{data("#{message(result)}\n\n#{flaky_explanation(result)}")}"
		else
			@io.puts "::error file=#{property(file)},line=#{line},title=#{property(title)}::#{data(message(result))}"
		end
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
		lines << "| Tests | Passed | Failed | Flaky | Quarantined | Errored | Skipped | Not run | Time |"
		lines << "|---|---|---|---|---|---|---|---|---|"
		lines << "| #{outcome.tests} | #{outcome.passed} | #{outcome.failed} | #{outcome.flaky} | #{outcome.quarantined} | #{outcome.errored + outcome.load_errors} | " \
			"#{outcome.skipped + outcome.pending} | #{outcome.not_run} | #{format('%.2f', outcome.duration)}s |"

		if @problems.any?
			lines << ""
			@problems.each do |path, test, result|
				lines << "- `#{test ? "#{path}:#{test['line']}" : path}` #{test ? name_of(test) : 'could not be loaded'}#{' (quarantined)' if result['quarantined']}#{' (flaky)' if result['passed_on_retry'] && !result['quarantined']}"
			end
		end

		lines << ""
		lines << "Seed #{@seed}"

		File.write(@summary_path, "#{lines.join("\n")}\n", mode: "a")
	end

	# An annotation (`level` "error" or "warning") on a line, as a workflow command.
	def self.annotation(level, file:, line:, title:, message:)
		"::#{level} file=#{property(file)},line=#{line},title=#{property(title)}::#{data(message)}"
	end

	# Workflow command escaping, from GitHub's toolkit.
	def self.data(text)
		text.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
	end

	def self.property(text)
		data(text).gsub(":", "%3A").gsub(",", "%2C")
	end

	private def data(text) = self.class.data(text)
	private def property(text) = self.class.property(text)
end
