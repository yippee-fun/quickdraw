# frozen_string_literal: true

# Coverage merged from every loader and worker (see CoverageCollector): totals,
# the least covered files and their uncovered lines, coverage of the lines
# changed since the last commit, and LCOV and JSON files for other tools.
# Runs in the coordinator, after loaders fork, so it may load libraries.
class Quickdraw::CoverageReport
	DIRECTORY = ".quickdraw/coverage"
	LCOV_PATH = "#{DIRECTORY}/lcov.info".freeze
	JSON_PATH = "#{DIRECTORY}/coverage.json".freeze
	HTML_PATH = "#{DIRECTORY}/index.html".freeze

	# Where the project's own code usually is, for finding files no test loads.
	SOURCE_PATTERN = "{app,lib,src}/**/*.rb"

	# `covered` of `total` lines, branches or methods.
	Count = Data.define(:covered, :total) do
		def ratio = (total > 0) ? covered.fdiv(total) : 1.0
		# Rounded down, so 99.9% isn't shown as 100%, in integers, so 29 of 100 isn't 28%.
		def percent = (total > 0) ? (covered * 100) / total : 100
		def +(other) = with(covered: covered + other.covered, total: total + other.total)
	end

	# A file's coverage. `uncovered` lists the lines never run.
	FileSummary = Data.define(:path, :lines, :branches, :methods, :uncovered)

	def initialize
		@files = {}
	end

	def any? = @files.any?

	# Adds coverage as CoverageCollector#take gives it.
	def add(files)
		Quickdraw::CoverageCollector.merge(@files, files)
	end

	def files
		@summaries ||= @files.sort.map do |path, data|
			lines = effective_lines(data)
			targets = (data["branches"] || {}).each_value.flat_map(&:values)
			methods = (data["methods"] || {}).values

			FileSummary.new(
				path:,
				lines: Count.new(covered: lines.count { |count| count&.positive? }, total: lines.count { |count| !count.nil? }),
				branches: Count.new(covered: targets.count(&:positive?), total: targets.size),
				methods: Count.new(covered: methods.count(&:positive?), total: methods.size),
				uncovered: lines.each_with_index.filter_map { |count, index| index + 1 if count == 0 },
			)
		end
	end

	# Each line's count, except that lines in methods never called count as
	# not run. Ruby counts a `def` line as run when the file loads, so a
	# one-line method no test calls would otherwise look covered.
	private def effective_lines(data)
		lines = data["lines"].dup
		called, uncalled = (data["methods"] || {}).partition { |_method, count| count > 0 }
		# A line can hold more than one method, so it's run if any of them was.
		called_lines = called.flat_map { |(_owner, _name, first_line, _column, last_line, _end_column), _count| (first_line..last_line).to_a }

		uncalled.each do |(_owner, _name, first_line, _column, last_line, _end_column), _count|
			((first_line..last_line).to_a - called_lines).each { |number| lines[number - 1] &&= 0 }
		end

		lines
	end

	def lines = files.sum(Count.new(covered: 0, total: 0), &:lines)
	def branches = files.sum(Count.new(covered: 0, total: 0), &:branches)
	def methods = files.sum(Count.new(covered: 0, total: 0), &:methods)

	# The files with the most uncovered lines, most first.
	def least_covered(limit)
		files.select { |file| file.uncovered.any? }.max_by(limit) { |file| file.uncovered.size }
	end

	# The project's Ruby files that no test loaded, so aren't in the totals.
	def never_loaded
		@never_loaded ||= Dir.glob(SOURCE_PATTERN).grep_v(Quickdraw::CoverageCollector::EXCLUDED).reject { |path| @files.key?(path) }.sort
	end

	# Lines changed since the last commit, and whether tests ran them, as
	# [Count, { path => uncovered lines }]. Changed files no test loaded count
	# every changed line as uncovered. Nil outside git or with no changed Ruby.
	def changed
		return @changed if defined?(@changed)

		@changed = (changes = changed_lines) && begin
			covered = 0
			total = 0
			uncovered = {}

			changes.each do |path, numbers|
				counts = (data = @files[path]) && effective_lines(data)
				numbers = numbers.select { |number| counts.nil? || !counts[number - 1].nil? }
				missed = numbers.select { |number| counts.nil? || counts[number - 1] == 0 }

				total += numbers.size
				covered += numbers.size - missed.size
				uncovered[path] = missed if missed.any?
			end

			[Count.new(covered:, total:), uncovered] if total > 0
		end
	end

	# "3-5, 9" for [3, 4, 5, 9].
	def self.ranges(numbers)
		numbers.slice_when { |previous, number| number != previous + 1 }
			.map { |run| (run.size == 1) ? run.first.to_s : "#{run.first}-#{run.last}" }
			.join(", ")
	end

	def write
		require "fileutils"
		require "json"
		FileUtils.mkdir_p(DIRECTORY)
		File.write(LCOV_PATH, lcov)
		File.write(JSON_PATH, JSON.pretty_generate(as_json))
		Quickdraw::CoverageHTML.write(self)
	end

	# See https://github.com/linux-test-project/lcov/blob/master/man/geninfo.1
	private def lcov
		# #files is in the same order.
		@files.sort.zip(files).map do |(path, data), summary|
			records = ["SF:#{File.expand_path(path)}"]
			methods = data["methods"] || {}

			methods.each { |(owner, name, line, *), _count| records << "FN:#{line},#{owner}##{name}" }
			methods.each { |(owner, name, *), count| records << "FNDA:#{count},#{owner}##{name}" }
			records << "FNF:#{methods.size}" << "FNH:#{methods.values.count(&:positive?)}"

			branch_total = 0
			branch_hit = 0

			(data["branches"] || {}).each_with_index do |((_type, _id, line, *), targets), block|
				targets.each_with_index do |(_target, count), index|
					records << "BRDA:#{line},#{block},#{index},#{count}"
					branch_total += 1
					branch_hit += 1 if count.positive?
				end
			end

			records << "BRF:#{branch_total}" << "BRH:#{branch_hit}"

			effective_lines(data).each_with_index { |count, index| records << "DA:#{index + 1},#{count}" if count }
			records << "LF:#{summary.lines.total}" << "LH:#{summary.lines.covered}" << "end_of_record"
			records.join("\n")
		end.join("\n") << "\n"
	end

	# Everything, as written to JSON_PATH: totals, then each file's lines, branches and methods.
	def as_json
		{
			"totals" => { "lines" => lines.to_h, "branches" => branches.to_h, "methods" => methods.to_h },
			"files" => @files.sort.to_h { |path, data| [path, file_json(data)] },
		}
	end

	private def file_json(data)
		branches = (data["branches"] || {}).map do |(type, _id, line, column, end_line, end_column), targets|
			{
				"type" => type.to_s,
				"line" => line,
				"column" => column,
				"end_line" => end_line,
				"end_column" => end_column,
				"targets" => targets.map { |(target, _target_id, target_line, *), count| { "type" => target.to_s, "line" => target_line, "count" => count } },
			}
		end

		methods = (data["methods"] || {}).map do |(owner, name, line, _column, end_line, _end_column), count|
			{ "name" => "#{owner}##{name}", "line" => line, "end_line" => end_line, "count" => count }
		end

		{ "lines" => effective_lines(data), "branches" => branches, "methods" => methods }
	end

	# The project's own Ruby changed since the last commit (see Changes).
	private def changed_lines
		Quickdraw::Changes.lines&.reject do |path, _lines|
			Quickdraw::CoverageCollector::EXCLUDED.match?(path) || path == Quickdraw::Loader::CONFIG_PATH
		end
	end
end
