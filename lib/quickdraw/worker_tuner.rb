# frozen_string_literal: true

# Chooses how many workers to run.
#
# Without history for a selection, it estimates. CPU-bound tests saturate at
# `cores`. Tests that wait (IO, sleep, network) can use more workers. A small
# suite gets fewer, so each worker has enough work to outweigh its startup. No
# count helps past the longest test.
#
# With history, it uses the count with the fastest recent runs, and every few
# runs tries a neighbouring count, so the choice follows the suite and machine.
class Quickdraw::WorkerTuner
	# Each worker should get at least this much work, in seconds.
	MINIMUM_WORK_PER_WORKER = 0.05

	# Quickdraw's own cost per test (scheduling, sending results), in seconds.
	# It dominates suites of very fast tests, which still need several workers.
	OVERHEAD_PER_TEST = 0.000_01

	# Runs between tries of a neighbouring count. It doubles after each try that
	# didn't find a faster count, up to the maximum, so a settled suite rarely
	# pays for exploring.
	EXPLORATION_INTERVAL = 4
	MAXIMUM_EXPLORATION_INTERVAL = 32

	# Recent runs of each count that are compared, by their median duration.
	SAMPLES = 3

	# Durations this close count as a tie.
	TOLERANCE = 0.03

	Choice = Data.define(:processes, :reason)

	def initialize(cores:, max:)
		@cores = cores
		@max = max
	end

	# `runs` are History::Run for the same selection, newest first. `expected` is
	# a History::Expected for the selected tests.
	def choose(runs:, expected:, waiting_share:)
		estimate = estimate(expected, waiting_share)
		runs = comparable(runs)
		return Choice.new(estimate, "estimated") if runs.empty?

		durations = runs.group_by(&:processes).transform_values do |runs_of_count|
			median(runs_of_count.first(SAMPLES).map(&:duration))
		end

		best = best(durations).clamp(1, @max)
		runs_since_exploring = runs.index { |run| run.worker_choice == "exploring" } || runs.size

		# When the last exploration found a clearly faster count, keep going in that direction.
		improving = runs_since_exploring < runs.size &&
			runs[runs_since_exploring].processes == best &&
			durations.except(best).values.all? { |duration| durations[best] < duration * (1 - TOLERANCE) }

		# An untried estimate far from the best count is worth trying straight away,
		# e.g. once a suite's first run shows it mostly waits.
		far = runs.none? { |run| run.processes == estimate } && (estimate >= best * 1.5 || estimate * 1.5 <= best)

		if (improving || far || runs_since_exploring >= interval(best, runs)) && (candidate = candidate(best, estimate, runs))
			Choice.new(candidate, "exploring")
		else
			Choice.new(best, "tuned")
		end
	end

	# Runs that ran far fewer tests than usual (say, because files failed to load)
	# would look fast, so they're left out.
	private def comparable(runs)
		return runs if runs.empty?

		typical = median(runs.map(&:tests))
		runs.select { |run| run.tests >= typical * 0.9 }
	end

	# The fewest workers whose runs are within the tolerance of the fastest, so
	# noise between equally good counts settles on the cheaper one.
	private def best(durations)
		fastest = durations.values.min
		durations.select { |_processes, duration| duration <= fastest * (1 + TOLERANCE) }.keys.min
	end

	private def interval(best, runs)
		losing_explorations = runs.select { |run| run.worker_choice == "exploring" }.take_while { |run| run.processes != best }.size
		[EXPLORATION_INTERVAL * (2 ** losing_explorations), MAXIMUM_EXPLORATION_INTERVAL].min
	end

	private def estimate(expected, waiting_share)
		return @cores.clamp(1, @max) unless expected.test_time.positive?

		work = expected.test_time + (expected.tests * OVERHEAD_PER_TEST)
		count = @cores / [1.0 - (waiting_share || 0.0), 0.1].max
		count = [count, work / MINIMUM_WORK_PER_WORKER].min
		count = [count, (expected.test_time / expected.longest_test).ceil].min if expected.longest_test&.positive?
		count.round.clamp(1, @max)
	end

	# The next count to try. The estimate comes first if it's untried, so a suite
	# that turns out to be IO-bound jumps straight to a high count. Then untried
	# steps either side of `best`: coarse (25%) before fine (10%), nearer the
	# estimate first. Once all are tried, whichever was tried longest ago.
	private def candidate(best, estimate, runs)
		last_tried = -> (count) { runs.index { |run| run.processes == count } }
		return estimate if estimate != best && last_tried.(estimate).nil?

		coarse = steps(best, 0.75, 4 / 3.0)
		fine = steps(best, 0.9, 1 / 0.9) - coarse

		[coarse, fine].each do |neighbours|
			untried = neighbours.select { |count| last_tried.(count).nil? }
			return untried.min_by { |count| (count - estimate).abs } if untried.any?
		end

		(coarse + fine).max_by { |count| last_tried.(count) }
	end

	private def steps(best, down, up)
		[(best * down).floor, (best * up).ceil].map { |count| count.clamp(1, @max) }.uniq - [best]
	end

	private def median(values)
		sorted = values.sort
		middle = sorted.size / 2
		sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
	end
end
