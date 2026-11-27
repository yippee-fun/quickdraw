# frozen_string_literal: true

# Which tests killed which mutants, for `quickdraw mutate --matrix`.
#
# A test is blind if it ran against mutants, in rows where every test ran,
# and killed none of them: it runs the code but doesn't check what it does.
# A test is redundant if every mutant it killed, another test killed too, in
# a row where every test ran. That's judged one test at a time: removing two
# redundant tests can lose a mutant only they killed.
class Quickdraw::Mutation::KillMatrix
	# A test (a Runner::Baseline) and how many mutants it ran against or killed.
	Entry = Data.define(:test, :count)

	# `results` are [Runner::Job, row] pairs (see Worker#mutate),
	# where a row is nil if the mutant didn't run.
	def initialize(results)
		@tests = {}
		@ran = Hash.new(0)
		@kills = Hash.new { |hash, key| hash[key] = [] }
		@killers = {}
		@complete = {}

		results.each do |job, row|
			next unless row

			id = job.mutant.id
			job.tests.each { |test| @tests[[test.path, test.index]] = test }
			@killers[id] = row["killed"].uniq
			@killers[id].each { |key| @kills[key] << id }
			@complete[id] = row["complete"]

			job.tests.each { |test| @ran[[test.path, test.index]] += 1 } if row["complete"]
		end
	end

	def blind
		entries = @ran.filter_map { |key, ran| Entry.new(test: @tests.fetch(key), count: ran) unless @kills.key?(key) }
		sorted(entries)
	end

	def redundant
		entries = @kills.filter_map do |key, ids|
			Entry.new(test: @tests.fetch(key), count: ids.size) if ids.all? { |id| @complete[id] && @killers[id].size > 1 }
		end

		sorted(entries)
	end

	# Of `tests` (Baselines), those that aren't the only test to kill some
	# mutant, in a row where every test ran.
	def without_unique_kill(tests)
		unique = {}
		@killers.each { |id, killers| unique[killers.first] = true if killers.one? && @complete[id] }
		tests.reject { |test| unique.key?([test.path, test.index]) }
	end

	# Mutants whose rows didn't finish, since a test crashed, hung or didn't load.
	def incomplete = @complete.count { |_id, complete| !complete }

	private def sorted(entries)
		entries.sort_by { |entry| [entry.test.path, entry.test.line] }
	end
end
