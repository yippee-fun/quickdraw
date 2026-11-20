# frozen_string_literal: true

# What `quickdraw mutate` runs, as Planner found it. `mutants` judge the tests,
# `ignored` are those marked equivalent, as [mutant, reason], and `reach` are
# the other mutants of the code the tests this changes run, to judge those
# tests by (with --unique-kills). Each mutant's id is unique in the run, and
# `keys` maps it to an id that stays the same across runs.
#
# `changed_tests` is { test path => lines the tests this adds or changes start
# at }. `test_files` run the mutants, from the coverage map if `mapped`.
# `processes` is how many workers to run by default, and `fingerprints` and
# `cache` are for Cache.
Quickdraw::Mutation::Plan = Data.define(:mutants, :ignored, :reach, :keys, :changed_tests, :test_files, :mapped, :warnings, :processes, :fingerprints, :cache) do
	# Changed tests still have to kill something of their own, if only to fail.
	def empty? = mutants.empty? && reach.empty? && changed_tests.empty?
end
