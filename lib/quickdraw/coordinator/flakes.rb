# frozen_string_literal: true

# The tests that passed on retry in a run, for `--flakes FILE` and config's
# on_flaky callbacks, and those it quarantines.
class Quickdraw::Coordinator::Flakes
	# With `quarantined` ({ key => true }), those tests can fail without failing
	# the run. Flakes are written to `path` as JSON, if there is one.
	def initialize(seed:, path:, quarantined:)
		@seed = seed
		@path = path
		@quarantined = quarantined
		@entries = []
	end

	# Set once config is read (see Coordinator#apply_settings).
	attr_writer :path, :quarantined

	# With --quarantine, a test that failed, or passed on retry, and was flaky
	# in recent runs (see History::QUARANTINE_WINDOW), so it doesn't fail the run.
	# Not one that crashed or hung its worker, whose failed exit fails the run anyway.
	def quarantined?(file, index, result)
		@quarantined && (result["failures"].any? || result["errors"].any?) && file.keys && @quarantined.key?(file.keys[index]) &&
			result["errors"].none? { |error| error["name"] in "Quickdraw::WorkerCrashed" | "Quickdraw::Timeout" }
	end

	# A test's result that passed on retry.
	def add(file, index, result)
		# As history keys tests, so tests with the same name in a file have different keys.
		key = file.keys&.fetch(index) || Quickdraw::History.keys(file.display_path, file.tests).fetch(index)
		@entries << Quickdraw::Flake.entry(file.display_path, file.tests[index], result, key:)
	end

	# Writes them to `path`, and has `loader` pass them to config's on_flaky
	# callbacks before it exits.
	def report(loader)
		return unless @path || @entries.any?

		require "json"
		json = JSON.generate(Quickdraw::Flake.report(Quickdraw::Flake.context(@seed), @entries))

		if @path
			require "fileutils"
			FileUtils.mkdir_p(File.dirname(@path))
			temporary = "#{@path}.#{Process.pid}.tmp"
			File.write(temporary, json)
			File.rename(temporary, @path)
		end

		loader&.send_flakes(json) if @entries.any?
	end
end
