# frozen_string_literal: true

# JUnit XML, which most CI systems display: a testsuite per file, a testcase
# per test, and a failure or error element for each problem, with what the
# test printed. A test that both failed an assertion and raised counts as an
# error.
class Quickdraw::Reporters::JUnit
	include Quickdraw::Reporters::Formatting

	def initialize(io: $stdout)
		@io = io
		@suites = Hash.new { |suites, file| suites[file] = [] }
	end

	def start(processes:, worker_choice:, seed:, estimate: nil)
		@seed = seed
	end

	def result(path, test, result)
		@suites[path] << [test, result]
	end

	def load_failed(path, error)
		@suites[path] << [nil, { "errors" => [error], "failures" => [], "duration" => 0 }]
	end

	def tick = nil

	def finish(outcome)
		@allow_flaky = outcome.allow_flaky
		all = @suites.values.flatten(1)

		xml = +%(<?xml version="1.0" encoding="UTF-8"?>\n)
		xml << %(<testsuites name="quickdraw" #{counts(all)} time="#{format('%.6f', outcome.duration)}">\n)

		@suites.each do |file, cases|
			time = cases.sum { |_test, result| result["duration"] || 0 }
			xml << %(  <testsuite name="#{attribute(file)}" #{counts(cases)} time="#{format('%.6f', time)}">\n)
			cases.each { |test, result| xml << test_case(file, test, result) }
			xml << "  </testsuite>\n"
		end

		xml << %(  <properties><property name="seed" value="#{@seed}"/></properties>\n)
		xml << "</testsuites>\n"

		@io.write(xml)
		@io.flush
	end

	private def counts(cases)
		statuses = cases.map { |_test, result| junit_status(result) }.tally
		skipped = statuses.fetch("skipped", 0) + statuses.fetch("pending", 0)
		%(tests="#{cases.size}" failures="#{statuses.fetch('failed', 0)}" errors="#{statuses.fetch('errored', 0)}" skipped="#{skipped}")
	end

	# A flaky test counts as its failure or error, unless flaky tests are allowed.
	private def junit_status(result)
		case Quickdraw::Outcome.status(result)
		in "flaky" if @allow_flaky then "passed"
		in "flaky" then result["errors"].any? ? "errored" : "failed"
		in status then status
		end
	end

	private def test_case(file, test, result)
		name = test ? test["description"] || "line #{test['line']}" : "#{file} could not be loaded"
		class_name = test&.fetch("class_name") || file
		attributes = %(name="#{attribute(name)}" classname="#{attribute(class_name)}" file="#{attribute(file)}" line="#{test&.fetch('line') || 1}" time="#{format('%.6f', result['duration'] || 0)}")

		failure_texts = result["failures"].map { |failure| "#{relative(failure['path'])}:#{failure['line']}\n#{plain(failure['message'])}" }
		flaky_text = flaky_explanation(result) if result["passed_on_retry"]
		# A passing test's flakyFailure and flakyError are Surefire's, which CI systems show.
		error_element, failure_element = (flaky_text && @allow_flaky) ? ["flakyError", "flakyFailure"] : ["error", "failure"]

		problem = if (error = result["errors"].first)
			body = [
				plain(error["message"]),
				*user_backtrace(error["backtrace"]).map { |frame| relative(frame) },
				*result["errors"].drop(1).map { |other| "#{other['name']}: #{plain(other['message'])}" },
				*failure_texts,
				*flaky_text,
			].join("\n")

			%(      <#{error_element} type="#{attribute(error['name'])}" message="#{attribute(one_line(error['message']))}">#{text(body)}</#{error_element}>\n)
		elsif (failure = result["failures"].first)
			%(      <#{failure_element} message="#{attribute(one_line(failure['message']))}">#{text([*failure_texts, *flaky_text].join("\n\n"))}</#{failure_element}>\n)
		elsif (skipped = result["skipped"])
			%(      <skipped message="#{attribute(skipped['pending'] ? 'pending' : skipped['reason'].to_s)}"/>\n)
		end

		# Stdout and stderr are captured together, in order, so both go in system-out.
		output = %(      <system-out>#{text(plain(result['output']))}</system-out>\n) if result["output"]

		problem ? %(    <testcase #{attributes}>\n#{problem}#{output}    </testcase>\n) : %(    <testcase #{attributes}/>\n)
	end

	# For the message attribute, which CI dashboards show as a summary.
	private def one_line(text)
		# Without assert_equal's label padding, but with the values' own spaces.
		plain(text).lines.map { |line| line.strip.sub(/\A(Expected|Actual) +/, '\1 ') }.reject(&:empty?).join(" ")[0, 200]
	end

	private def text(value)
		escape(value)
	end

	# XML parsers turn literal newlines and tabs in attributes into spaces.
	private def attribute(value)
		escape(value).gsub("\n", "&#10;").gsub("\r", "&#13;").gsub("\t", "&#9;")
	end

	# XML 1.0 can't contain most control characters, even escaped.
	private def escape(value)
		Quickdraw.utf8(value.to_s)
			.gsub(/[^\t\n\r -퟿-�\u{10000}-\u{10FFFF}]/, "")
			.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("'", "&apos;")
	end
end
