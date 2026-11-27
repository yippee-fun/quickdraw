# frozen_string_literal: true

# What a `quickdraw mutate` run found, for people, agents or as JSON, and its
# exit status. Mutants run only to judge the tests this changes don't count.
class Quickdraw::Mutation::Report
	include Quickdraw::Commands::Output
	include Quickdraw::Reporters::Formatting

	# Tests listed with each survivor.
	SHOWN_TESTS = 3
	# Blind and redundant tests listed by human and agent reports, not JSON.
	SHOWN_MATRIX_TESTS = 20
	# Survivors the agent format lists, a line each. The rest are a command away.
	SHOWN_SURVIVORS = 20

	KILLED = ["killed", "timeout", "crashed"].freeze

	# `outcomes` and, with the matrix, `rows`, are what Runner#call yielded for
	# each job. `reach_ids` and `cached` are the ids of mutants run only to
	# judge the tests this changes, and whose outcomes came from the cache.
	# `missing` are the subjects no worker found, and `broken` the test files
	# that failed to load, crashed or timed out. `unique_tests` are the tests
	# (Baselines) this changes, with --unique-kills.
	def initialize(io, plan, format:, threshold:, matrix:, outcomes:, rows:, jobs:, reach_ids:, cached:, uncovered:, missing:, broken:, unique_tests:, interrupted:, duration:, carried: {})
		@io = io
		@format = format
		@threshold = threshold
		@matrix = matrix
		@mutants = plan.mutants
		@reach = plan.reach
		@ignored = plan.ignored
		@keys = plan.keys
		@outcomes = outcomes
		@jobs = jobs
		@reach_ids = reach_ids
		@cached = cached
		@carried = carried
		@uncovered = uncovered
		@missing = missing
		@broken = broken
		@unique_tests = unique_tests
		@interrupted = interrupted
		@duration = duration

		counted = outcomes.reject { |job, _outcome| reach_ids.key?(job.mutant.id) }
		@killed, rest = counted.partition { |_job, (status, *)| KILLED.include?(status) }
		@survived = rest.select { |_job, (status, *)| status == "survived" }
		# Including those run only to judge the tests this changes, which then can't be.
		@errors = outcomes.reject { |_job, (status, *)| KILLED.include?(status) || status == "survived" }
		@survived.sort_by! { |job, _outcome| [job.mutant.subject.path, job.mutant.line, job.mutant.id] }
		tested = @killed.size + @survived.size
		@score = (100.0 * @killed.size / tested if tested > 0)
		@kill_matrix = Quickdraw::Mutation::KillMatrix.new(rows) if matrix || unique_tests
		@not_unique = @kill_matrix.without_unique_kill(unique_tests.reject(&:exempt)) if unique_tests
		@from_cache = counted.count { |job, _outcome| cached.key?(job.mutant.id) }
	end

	# Prints the report, and returns the exit status. Agents are pointed to
	# --show for the survivors if they were saved (see #survivors).
	def call(survivors_saved:)
		case @format
		in "human" then report_for_people
		in "agent" then report_for_agents(survivors_saved:)
		in "json" then report_json
		end

		annotate if Quickdraw::Reporters::GitHubActions.active? && @format != "json"

		exit_status
	end

	# The [job, outcome] of each mutant counted as killed.
	attr_reader :killed

	# For --show (see Survivors).
	def survivors
		@survived.map do |job, _outcome|
			mutant = job.mutant

			{
				"id" => @keys.fetch(mutant.id),
				"heading" => "SURVIVED #{@keys.fetch(mutant.id)} #{relative(mutant.subject.path)}:#{mutant.line} #{mutant.subject.label}: #{mutant.description}",
				"change" => snippet(mutant),
				"tests" => job.tests.map { |test| "#{relative(test.path)}:#{test.line} #{test.name}" },
			}
		end
	end

	# A run that couldn't run everything it should have isn't a pass, whatever its score.
	private def exit_status
		if @interrupted then 130
		elsif @score && @score < @threshold then 1
		elsif @not_unique&.any? then 1
		elsif @errors.any? || @broken.any? || @missing.any? then 1
		else 0
		end
	end

	private def report_for_people
		# As test runs show problems: a badge, what changed and where, then the
		# change as a diff of the original (-) and the mutant (+).
		@survived.each do |job, _outcome|
			mutant = job.mutant
			@io.puts "#{label('SURVIVED', 43)} #{bold(mutant.description)}  #{dim("#{mutant.subject.label} · #{relative(mutant.subject.path)}:#{mutant.line} · #{@keys.fetch(mutant.id)}")}"
			@io.puts
			snippet(mutant).each { |line| @io.puts "    #{line.start_with?('-') ? red(line) : green(line)}" }
			@io.puts
			@io.puts "  #{dim("#{pluralize(job.tests.size, 'test')} ran it and passed: #{tests(job)}")}"
			@io.puts
		end

		if problems.any?
			problems.each { |problem| @io.puts "#{yellow('!')} #{problem}" }
			@io.puts
		end

		# Each section ends with a blank line, so the verdict needs one only after nothing.
		sections = [@survived.any?, problems.any?]
		sections << print_kill_matrix if @matrix
		sections << print_unique_kills if @not_unique

		counts = if @score
			["#{format_score(@score)} mutation score", "#{@killed.size} killed", (red("#{@survived.size} survived") if @survived.any?)]
		elsif @mutants.empty?
			["No mutants on changed lines"]
		else
			["No mutants ran"]
		end

		counts << yellow("#{@uncovered.size} on lines no test runs") if @uncovered.any?
		counts << dim("#{@ignored.size} marked equivalent") if @ignored.any?
		badge, background = (exit_status == 0) ? ["PASSED", 42] : ["FAILED", 41]
		@io.puts if sections.none?
		@io.puts "#{label(badge, background)} #{counts.compact.join(dim(' · '))}"
		@io.puts "#{beside_label(badge)}#{dim(rate)}"
	end

	# A line per survivor, with its id. Each one's change, and the tests that
	# ran it, are a command away (see Survivors.show), since agents pay for every line.
	private def report_for_agents(survivors_saved:)
		@survived.first(SHOWN_SURVIVORS).each do |job, _outcome|
			mutant = job.mutant
			@io.puts "SURVIVED #{@keys.fetch(mutant.id)} #{relative(mutant.subject.path)}:#{mutant.line} #{mutant.subject.label}: #{mutant.description} (#{pluralize(job.tests.size, 'test')} ran it)"
		end

		if @survived.size > SHOWN_SURVIVORS
			@io.puts "and #{pluralize(@survived.size - SHOWN_SURVIVORS, 'more survivor')}#{", which #{Quickdraw::Reporters.command} mutate --show all lists with the rest" if survivors_saved}"
		end

		problems.each { |problem| @io.puts problem }

		if @matrix
			matrix_entries(@kill_matrix.blind).each { |entry| @io.puts "BLIND: #{relative(entry.test.path)}:#{entry.test.line} #{entry.test.name} ran against #{pluralize(entry.count, 'mutant')} and killed none" }
			matrix_entries(@kill_matrix.redundant).each { |entry| @io.puts "REDUNDANT: #{relative(entry.test.path)}:#{entry.test.line} #{entry.test.name}. Another test also killed each mutant it killed (#{entry.count})" }
		end
		@io.puts "NOT COVERED: #{pluralize(@uncovered.size, 'mutant')} on lines no test runs: #{uncovered_lines}" if @uncovered.any?

		if @not_unique
			@not_unique.first(SHOWN_MATRIX_TESTS).each do |test|
				@io.puts "NOT UNIQUE: #{relative(test.path)}:#{test.line} #{test.name} kills no mutant another test doesn't. Make it check something no other test does, remove it, or mark it `mutation: false` if what it tests can't be mutated."
			end

			@io.puts "and #{pluralize(@not_unique.size - SHOWN_MATRIX_TESTS, 'more test')}" if @not_unique.size > SHOWN_MATRIX_TESTS
			judged = @unique_tests.count { |test| !test.exempt }
			@io.puts "UNIQUE KILLS: #{(judged == 1) ? 'The test' : "Each of the #{judged} tests"} this changes kills a mutant no other test does." if @not_unique.empty? && judged > 0
		end

		if @score
			@io.puts "MUTATION SCORE: #{format_score(@score)} (#{@killed.size} of #{@killed.size + @survived.size} killed#{", #{@survived.size} survived" if @survived.any?}#{", #{@ignored.size} marked equivalent" if @ignored.any?}). #{rate}"
		elsif @mutants.empty?
			@io.puts "NO MUTANTS ON CHANGED LINES. #{rate}"
		else
			@io.puts "NO MUTANTS RAN. #{rate}"
		end

		if @survived.any? && survivors_saved
			command = "#{Quickdraw::Reporters.command} mutate --show"
			@io.puts "Details: #{command} #{@keys.fetch(@survived.first.first.mutant.id)} (the change, and the tests that ran it). All survivors: #{command} all"
		end
	end

	private def report_json
		require "json"

		@io.puts JSON.generate({
			"score" => @score&.round(2),
			"threshold" => @threshold,
			"mutants" => @mutants.size,
			"killed" => @killed.size,
			"timed_out" => @killed.count { |_job, (status, *)| status == "timeout" },
			"survived" => @survived.size,
			"uncovered" => @uncovered.size,
			"ignored" => @ignored.map do |mutant, reason|
				{ "id" => @keys.fetch(mutant.id), "path" => relative(mutant.subject.path), "line" => mutant.line, "method" => mutant.subject.label, "description" => mutant.description, "reason" => reason }
			end,
			"errors" => @errors.count { |job, _outcome| !@reach_ids.key?(job.mutant.id) },
			"missing" => missing_mutants(@mutants),
			"cached" => @from_cache,
			"duration" => @duration.round(3),
			"interrupted" => !!@interrupted,
			"survivors" => @survived.map do |job, _outcome|
				mutant = job.mutant

				{
					"id" => @keys.fetch(mutant.id),
					"path" => relative(mutant.subject.path),
					"line" => mutant.line,
					"method" => mutant.subject.label,
					"description" => mutant.description,
					"before" => mutant.before,
					"after" => mutant.after,
					"tests" => job.tests.map { |test| { "path" => relative(test.path), "line" => test.line, "name" => test.name } },
				}
			end,
			"uncovered_lines" => @uncovered.group_by { |mutant| relative(mutant.subject.path) }.transform_values { |list| list.map(&:line).uniq.sort },
			"missing_methods" => @missing.map { |subject| { "path" => relative(subject.path), "line" => subject.line, "method" => subject.label } },
			**(@matrix ? { "matrix" => matrix_json } : {}),
			**(@not_unique ? { "unique_kills" => unique_kills_json } : {}),
		})
	end

	# On GitHub Actions, each survivor and test that isn't the only one to kill
	# a mutant as an error on its line, so they show in a pull request's diff.
	private def annotate
		github = Quickdraw::Reporters::GitHubActions

		@survived.each do |job, _outcome|
			mutant = job.mutant
			message = "No test noticed this change (#{@keys.fetch(mutant.id)}):\n#{snippet(mutant).join("\n")}\n\n#{pluralize(job.tests.size, 'test')} ran it: #{tests(job, locations: true)}"
			@io.puts github.annotation("error", file: relative(mutant.subject.path), line: mutant.line, title: "Mutant survived: #{mutant.description}", message:)
		end

		@not_unique&.each do |test|
			message = "It kills no mutant another test doesn't. Make it check something no other test does, remove it, or mark it `mutation: false` if what it tests can't be mutated."
			@io.puts github.annotation("error", file: relative(test.path), line: test.line, title: "#{test.name} isn't the only test to kill any mutant", message:)
		end
	end

	# Tests that ran mutants and killed none, then tests whose kills others
	# made too. Whether it printed anything.
	private def print_kill_matrix
		sections = [
			["Blind tests", "ran against mutants and killed none", @kill_matrix.blind, "ran against"],
			["Redundant tests", "every mutant they killed, another test killed too, so each could go, one at a time", @kill_matrix.redundant, "killed"],
		].reject { |_title, _explanation, entries, _counted| entries.empty? }

		sections.each do |title, explanation, entries, counted|
			@io.puts "#{bold(title)} #{dim(explanation)}"
			matrix_entries(entries).each do |entry|
				@io.puts "  #{relative(entry.test.path)}:#{entry.test.line} #{entry.test.name}  #{dim("#{counted} #{pluralize(entry.count, 'mutant')}")}"
			end
			@io.puts "  #{dim("and #{entries.size - SHOWN_MATRIX_TESTS} more")}" if entries.size > SHOWN_MATRIX_TESTS
			@io.puts
		end

		sections.any?
	end

	private def matrix_entries(entries) = entries.first(SHOWN_MATRIX_TESTS)

	# The tests this adds or changes that aren't the only one to kill a
	# mutant. Whether it printed anything.
	private def print_unique_kills
		judged = @unique_tests.count { |test| !test.exempt }
		return false if judged == 0

		if @not_unique.empty?
			@io.puts "#{green('✓')} #{(judged == 1) ? 'The test' : "Each of the #{judged} tests"} this changes kills a mutant no other test does."
			@io.puts
			return true
		end

		@io.puts "#{bold('Tests that kill no mutant of their own')} #{dim('each test this changes must kill a mutant no other test does')}"

		@not_unique.first(SHOWN_MATRIX_TESTS).each do |test|
			@io.puts "  #{relative(test.path)}:#{test.line} #{test.name}"
		end

		@io.puts "  #{dim("and #{@not_unique.size - SHOWN_MATRIX_TESTS} more")}" if @not_unique.size > SHOWN_MATRIX_TESTS
		@io.puts "  #{dim('Make each check something no other test does, remove it, or mark it `mutation: false` if what it tests can’t be mutated.')}"
		@io.puts
		true
	end

	private def unique_kills_json
		{
			"tests" => @unique_tests.map { |test| { "path" => relative(test.path), "line" => test.line, "name" => test.name, "exempt" => test.exempt } },
			"not_unique" => @not_unique.map { |test| { "path" => relative(test.path), "line" => test.line, "name" => test.name } },
			"incomplete" => @kill_matrix.incomplete,
			# Of the mutants run only to judge them.
			"errors" => @errors.count { |job, _outcome| @reach_ids.key?(job.mutant.id) },
			"missing" => missing_mutants(@reach),
		}
	end

	private def matrix_json
		{
			"blind" => @kill_matrix.blind.map { |entry| matrix_test_json(entry, "ran") },
			"redundant" => @kill_matrix.redundant.map { |entry| matrix_test_json(entry, "killed") },
			"incomplete" => @kill_matrix.incomplete,
		}
	end

	private def matrix_test_json(entry, count)
		{ "path" => relative(entry.test.path), "line" => entry.test.line, "name" => entry.test.name, count => entry.count }
	end

	# Interruptions, mutants that couldn't run, and methods that couldn't be found.
	private def problems
		messages = []
		messages << "Interrupted after #{@outcomes.size} of #{pluralize(@jobs.size, 'mutant')}." if @interrupted

		@errors.group_by { |_job, (status, *)| status }.each do |status, errors|
			job, (_status, reason) = errors.first

			messages << case status
			in "unapplied" then "#{pluralize(errors.size, 'mutant')} couldn’t be applied, such as at #{relative(job.mutant.subject.path)}:#{job.mutant.line}: #{reason}"
			in "lost" then "#{pluralize(errors.size, 'mutant')} didn’t finish, since the worker running #{errors.one? ? 'it' : 'them'} exited."
			in "unloaded"
				paths = errors.map { |_job, (_status, path)| relative(path) }.uniq
				"#{pluralize(errors.size, 'mutant')} didn’t run every test that runs #{errors.one? ? 'it' : 'them'}, since #{list(paths)} loaded in one worker but failed to load in another."
			end
		end

		if @missing.any?
			labels = @missing.first(3).map { |subject| "#{subject.label} (#{relative(subject.path)}:#{subject.line})" }
			messages << "Couldn’t find #{list(labels)} once tests had loaded, so #{(missing_mutants == 1) ? 'its mutant' : "#{missing_mutants} mutants"} didn’t run."
		end

		incomplete = @kill_matrix&.incomplete || 0

		if incomplete > 0
			judgements = [("blind or redundant" if @matrix), ("counted as the only one to kill #{(incomplete == 1) ? 'it' : 'them'}" if @not_unique)].compact
			messages << "Not every test ran against #{pluralize(incomplete, 'mutant')}, since a test crashed, hung or didn’t load, so #{(incomplete == 1) ? 'its tests' : 'their tests'} can’t be #{judgements.join(', or ')}."
		end

		messages
	end

	# Of `mutants`, those whose method couldn't be found.
	private def missing_mutants(mutants = [*@mutants, *@reach])
		ids = @missing.to_h { |subject| [subject.id, true] }
		mutants.count { |mutant| ids.key?(mutant.subject.id) }
	end

	# The change as removed and added lines, without their common indentation.
	private def snippet(mutant)
		before = mutant.before.lines(chomp: true)
		after = mutant.after.lines(chomp: true)
		indentation = (before + after).reject { |line| line.strip.empty? }.map { |line| line[/\A\s*/].size }.min || 0
		before.map { |line| "- #{line[indentation..]}" } + after.map { |line| "+ #{line[indentation..]}" }
	end

	private def tests(job, locations: false)
		names = job.tests.first(SHOWN_TESTS).map { |test| locations ? "#{relative(test.path)}:#{test.line} #{test.name}" : test.name }
		names << "and #{job.tests.size - SHOWN_TESTS} more" if job.tests.size > SHOWN_TESTS
		names.join(", ")
	end

	private def uncovered_lines
		@uncovered.group_by { |mutant| relative(mutant.subject.path) }.map do |path, list|
			"#{path}:#{list.map(&:line).uniq.sort.join(',')}"
		end.join(" ")
	end

	# How many mutants ran, and how fast, not counting those from the cache.
	private def rate
		outcomes = @outcomes.reject { |job, _outcome| @cached.key?(job.mutant.id) || @carried.key?(job.mutant.id) }
		ran = outcomes.size
		judging = outcomes.count { |job, _outcome| @reach_ids.key?(job.mutant.id) }
		judged = case judging
		in 0 then ""
		in ^ran then " to judge the tests this changes"
		else " (#{judging} to judge the tests this changes)"
		end

		seconds = format("%.2fs", @duration)
		return "All #{pluralize(@cached.size, 'mutant')} unchanged since an earlier run, so none ran, in #{seconds}" if ran == 0 && @cached.any? && @carried.empty?

		cached = ", and #{@cached.size} unchanged since an earlier run" if @cached.any?
		carried = ", and #{@carried.size} killed in the last run, not run again" if @carried.any?
		"#{pluralize(ran, 'mutant')}#{judged} in #{seconds}#{format(' (%.0f/s)', ran / @duration) if ran > 0}#{cached}#{carried}"
	end

	private def format_score(score)
		"#{(score % 1).zero? ? score.to_i : format('%.1f', score)}%"
	end
end
