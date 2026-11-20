# frozen_string_literal: true

# Mutants' outcomes from earlier runs, so `quickdraw mutate` runs again only
# those whose method, tests, or the code their tests run have changed. Each
# is keyed by a hash of the mutant's id and what its outcome depends on (see
# Planner#fingerprints), and kept in PATH as JSON, with paths relative to the
# project, so a cache restored in CI at another path still works.
class Quickdraw::Mutation::Cache
	PATH = ".quickdraw/mutants.json"

	# Files whose changes could change any mutant's outcome.
	ENVIRONMENT = ["Gemfile.lock", "gems.locked", "config/quickdraw.rb"].freeze

	# Outcomes that are the same whenever nothing they depend on changes, unlike
	# timeouts and crashes, which can depend on the machine.
	KEPT = ["killed", "survived"].freeze

	# The most kept, dropping those used least recently.
	LIMIT = 50_000

	# The entries in PATH, or none if it's missing or unreadable.
	def self.read
		require "json"
		entries = JSON.parse(File.read(PATH, encoding: Encoding::UTF_8))
		(Hash === entries) ? entries : {}
	rescue SystemCallError, JSON::ParserError
		{}
	end

	def initialize(entries)
		@entries = entries
	end

	# [outcome, row] for `key`, or nil. The row is nil if it was found without
	# running every test (see Runner).
	def fetch(key)
		entry = @entries[key] or return
		outcome, row = entry

		# Moved to the end, as recently used.
		@entries[key] = @entries.delete(key)
		[expand_outcome(outcome), row&.merge("killed" => row.fetch("killed").map { |path, index| [File.expand_path(path), index] })]
	end

	def store(key, outcome, row)
		return unless KEPT.include?(outcome.first)

		@entries.delete(key)
		@entries[key] = [relative_outcome(outcome), row && row.merge("killed" => row.fetch("killed").map { |path, index| [relative(path), index] })]
	end

	def write
		require "json"
		@entries.shift while @entries.size > LIMIT

		begin
			Dir.mkdir(File.dirname(PATH))
		rescue Errno::EEXIST
			nil
		end

		temporary = "#{PATH}.#{Process.pid}"
		File.write(temporary, JSON.generate(@entries))
		File.rename(temporary, PATH)
	end

	private def relative_outcome(outcome)
		case outcome
		in ["killed", [path, index]] then ["killed", [relative(path), index]]
		else outcome
		end
	end

	private def expand_outcome(outcome)
		case outcome
		in ["killed", [path, index]] then ["killed", [File.expand_path(path), index]]
		else outcome
		end
	end

	private def relative(path) = path.delete_prefix("#{Dir.pwd}/")
end
