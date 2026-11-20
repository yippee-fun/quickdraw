# frozen_string_literal: true

# Shares the run's cores out between groups by how long their tests are
# expected to take, each worker using its group's cores (see
# Configuration::Group). Reads the coordinator's files, workers and loaders as
# they change.
class Quickdraw::Coordinator::Scheduler
	# Without history, a guess, which only matters against groups' estimates.
	DEFAULT_FILE_SECONDS = 0.1

	# `groups` are as the first loader reports them, and `group_of` is each test
	# file's group, by display path. Workers use up to `core_budget` cores
	# between them (see #fits?).
	def initialize(groups:, group_of:, plan:, core_budget:, unloaded:, files:, workers:, leaving:, loaders:, retries:)
		@group_cores = groups.to_h { |name, _patterns, _gemfile, cores| [name, cores || 1] }
		@group_file_seconds = groups.to_h { |name, _patterns, _gemfile, _cores, seconds| [name, seconds] }
		@group_of = group_of
		@plan = plan
		@core_budget = core_budget
		@unloaded = unloaded
		@files = files
		@workers = workers
		@leaving = leaving
		@loaders = loaders
		@retries = retries
	end

	# How many of `processes` workers to start in each group with files to
	# load: one for each first, slowest first, then each next to the group
	# whose tests would take longest per worker.
	def allocate(processes)
		work = @unloaded.map { |_path, display_path| @group_of[display_path] }.uniq.to_h { |group| [group, remaining_seconds(group)] }
		allocation = work.transform_values { 0 }
		used = 0

		while allocation.values.sum < processes
			# The group of files in none is nil.
			fitting = work.keys.select { |name| used.zero? || used + cores(name) <= @core_budget }
			break if fitting.empty?

			group = fitting.max_by { |name| allocation[name].zero? ? [1, work[name]] : [0, work[name] / allocation[name]] }
			allocation[group] += 1
			used += cores(group)
		end

		allocation
	end

	# A worker added in `group`, since idle CPU is room for its cores.
	def added(group)
		@core_budget += cores(group)
	end

	# The loader, other than `except`, whose group has the most work left per
	# worker, so workers stay busy across groups.
	# Only one whose workers fit in the cores the run uses, unless `fitting` is false.
	def busiest_loader(except: nil, fitting: true)
		candidates = @loaders.each_value.reject do |loader|
			loader.equal?(except) || loader.spares.empty? || loader.status || !work_left?(loader.group) || (fitting && !fits?(loader.group))
		end

		candidates.max_by do |loader|
			workers = @workers.each_value.count { |other| other.loader.equal?(loader) }
			remaining_seconds(loader.group).fdiv(workers + 1)
		end
	end

	def work_left?(group)
		@unloaded.any? { |_path, display_path| @group_of[display_path] == group } ||
			@files.each_value.any? { |file| file.pending.any? && @group_of[file.display_path] == group } ||
			@retries.waiting?(group)
	end

	# How many cores a worker in `group` uses (see Configuration::Group).
	private def cores(group) = @group_cores.fetch(group, 1)

	# The cores workers use, counting those moving between groups at their new
	# group's. Not those of workers whose group has run out of work, which
	# would otherwise keep a group that has work from getting their cores.
	private def cores_in_use
		working = Hash.new { |groups, group| groups[group] = work_left?(group) }
		busy = @workers.each_value.sum { |worker| (worker.idle && !working[worker.group] && worker.queued_retries.empty?) ? 0 : cores(worker.group) }
		busy + @leaving.each_value.sum { |_worker, loader| loader ? cores(loader.group) : 0 }
	end

	# Whether a worker can start in `group` within the run's cores. When none
	# is busy, one can, so every group runs, even with fewer cores than its
	# workers use.
	private def fits?(group)
		others = cores_in_use
		others.zero? || others + cores(group) <= @core_budget
	end

	# Seconds of tests left in `group`: from history and how this run's have
	# gone so far, or else as files are expected to take (see #file_seconds).
	private def remaining_seconds(group)
		unloaded = @unloaded.sum { |_path, display_path| (@group_of[display_path] == group) ? file_seconds(display_path) : 0.0 }

		loaded = @files.each_value.sum do |file|
			next 0.0 unless file.pending.any? && @group_of[file.display_path] == group

			file.estimated_pending_time || (file_seconds(file.display_path) * file.pending.size / [file.size, 1].max)
		end

		unloaded + loaded
	end

	# How long a file is expected to take: from history, or else as its
	# group's files are, or else as the average file is.
	private def file_seconds(display_path)
		@plan&.files&.dig(display_path, 1) || @group_file_seconds[@group_of[display_path]] || average_file_seconds
	end

	private def average_file_seconds
		@average_file_seconds ||= begin
			totals = @plan&.files&.each_value&.map { |_count, total, _longest| total }
			totals&.any? ? totals.sum / totals.size : DEFAULT_FILE_SECONDS
		end
	end
end
