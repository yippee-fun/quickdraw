# frozen_string_literal: true

# A test that failed, then passed when retried, as `config.on_flaky` sees it
# (see Configuration#on_flaky) and `--flakes FILE` writes it.
#
# `kind` says what the retries suggest:
# - `:nondeterministic`: it passed when run again in the same worker, so it
#   fails some of the time on its own (timing, randomness, the network);
# - `:order_dependent`: it failed again in the same worker, then passed in a
#   fresh one, so it likely depends on what ran before it;
# - `:unknown`: its worker crashed before it could be run again there.
#
# `attempts` are hashes with `in` (`"first run"`, `"same worker"` or `"fresh
# worker"`), `status`, `duration`, and the `failures` and `errors` of each
# run. `key` is the same for the test from run to run, for grouping reports.
Quickdraw::Flake = Data.define(:key, :path, :line, :name, :kind, :attempts, :seed, :rerun, :commit, :branch, :ci_url) do
	# Context for a run's flakes: its seed, commit, branch and CI build.
	def self.context(seed)
		{
			"seed" => seed,
			"commit" => ENV["GITHUB_SHA"] || git("rev-parse", "HEAD"),
			"branch" => [ENV["GITHUB_HEAD_REF"], ENV["GITHUB_REF_NAME"]].find { |name| !name.to_s.empty? } || git("rev-parse", "--abbrev-ref", "HEAD"),
			"ci_url" => ci_url,
		}
	end

	# A flaky `result` of `test` in `path`, as JSON data. `key` is the test's
	# history key (see History.keys).
	def self.entry(path, test, result, key:)
		{
			"key" => Quickdraw.stable_hash(key).to_s(16).rjust(16, "0")[0, 12],
			"path" => path,
			"line" => test["line"],
			"name" => Quickdraw.utf8(Quickdraw::Filter.name_of(test)),
			"kind" => result.fetch("flake"),
			"attempts" => result.fetch("attempts"),
		}
	end

	# A run of a test, for its attempts, with any text made valid UTF-8 for JSON.
	def self.attempt(result, place)
		{
			"in" => place,
			"status" => Quickdraw::Outcome.status(result),
			"duration" => result["duration"],
			"failures" => utf8(result["failures"]),
			"errors" => utf8(result["errors"]),
		}
	end

	def self.utf8(value)
		case value
		in String then Quickdraw.utf8(value)
		in Array then value.map { |item| utf8(item) }
		in Hash then value.to_h { |key, item| [key, utf8(item)] }
		else value
		end
	end

	# The JSON `--flakes FILE` holds.
	def self.report(context, entries)
		{ **context, "flakes" => entries.map { |entry| entry.merge("rerun" => rerun(entry, context)) } }
	end

	def self.from(entry, context)
		attempts = entry.fetch("attempts").map { |attempt| attempt.transform_keys(&:to_sym) }

		new(
			key: entry.fetch("key"),
			path: entry.fetch("path"),
			line: entry.fetch("line"),
			name: entry.fetch("name"),
			kind: entry.fetch("kind").to_sym,
			attempts:,
			seed: context.fetch("seed"),
			rerun: rerun(entry, context),
			commit: context["commit"],
			branch: context["branch"],
			ci_url: context["ci_url"],
		)
	end

	def self.rerun(entry, context)
		location = "#{entry.fetch('path')}:#{entry.fetch('line')}"
		# So a path starting with "-" isn't taken for an option.
		separator = "-- " if location.start_with?("-")
		"#{Quickdraw::Reporters.command} --seed #{context.fetch('seed')} #{separator}#{Quickdraw::Reporters.shell_quote(location)}"
	end

	def self.ci_url
		if ENV["GITHUB_RUN_ID"] && ENV["GITHUB_REPOSITORY"]
			"#{ENV.fetch('GITHUB_SERVER_URL', 'https://github.com')}/#{ENV['GITHUB_REPOSITORY']}/actions/runs/#{ENV['GITHUB_RUN_ID']}#{"/attempts/#{ENV['GITHUB_RUN_ATTEMPT']}" if ENV['GITHUB_RUN_ATTEMPT']}"
		else
			ENV["BUILDKITE_BUILD_URL"] || ENV["CI_JOB_URL"] || ENV["CIRCLE_BUILD_URL"]
		end
	end

	def self.git(*arguments)
		output = IO.popen(["git", *arguments], err: File::NULL, &:read)
		output.strip if $?.success? && !output.strip.empty?
	rescue SystemCallError
		nil
	end
	private_class_method :git, :ci_url, :utf8
end
