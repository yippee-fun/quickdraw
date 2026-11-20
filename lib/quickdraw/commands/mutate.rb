# frozen_string_literal: true

# Mutation testing: changes the code in methods in small ways (mutants), and
# runs the tests that run each change to see whether any fails. A mutant no
# test notices (a survivor) is code the tests run but don't check.
#
# Mutates the lines changed since the last commit, or the files and lines
# given. Mutants are applied in forked workers, never on disk (see Runner).
class Quickdraw::Commands::Mutate
	include Quickdraw::Commands::Output
	include Quickdraw::Reporters::Formatting

	FORMATS = ["human", "agent", "json"].freeze
	SPECIFICATION = /\A(?<path>.+?)(?::(?<first>\d+)(?:-(?<last>\d+))?)?\z/

	# A mutant's tests may take this many times as long as they did unmutated,
	# plus TIMEOUT_MARGIN seconds, before it counts as looping forever, which kills it.
	TIMEOUT_FACTOR = 3
	TIMEOUT_MARGIN = 0.5

	# Tests listed with each survivor.
	SHOWN_TESTS = 3
	# Blind and redundant tests listed by human and agent reports, not JSON.
	SHOWN_MATRIX_TESTS = 20
	# Survivors the agent format lists, a line each. The rest are a command away.
	SHOWN_SURVIVORS = 20
	# The last run's survivors, for --show.
	LAST_PATH = ".quickdraw/last-mutate.json"

	KILLED = ["killed", "timeout", "crashed"].freeze

	# Fixed, so a test that uses rand, such as a property, kills the same mutants every time.
	DEFAULT_SEED = 0

	def initialize(args, io: $stdout)
		@args = args.dup
		@io = io
	end

	def call
		@started_at = now

		options = case parse
		in Integer => status then return status
		in Hash => options then options
		end

		return show(options[:show]) if options[:show]

		unless Process.respond_to?(:fork)
			warn "mutate needs fork, which this platform doesn’t support."
			return 2
		end

		@format = options[:format] || (Quickdraw::Reporters.agent? ? "agent" : "human")
		@threshold = options[:threshold]
		@seed = options[:seed]
		@unique_kills = options[:unique_kills]
		@matrix = options[:matrix]
		# Which tests are the only ones to kill a mutant is for the matrix to say.
		@tracks_kills = @matrix || @unique_kills

		# Prism, sqlite3 and etc load in a throwaway process, so they can't reach workers.
		plan = Quickdraw.isolate { prepare(options[:targets], options[:base], unique_kills: @unique_kills) }

		if String === plan
			warn plan
			return 2
		end

		plan[:warnings].each { |message| warn message }
		# Ids for the ignored too, so marking one doesn't change its neighbours'.
		all = [*plan[:mutants], *plan[:ignored].map(&:first), *plan[:reach]].each_with_index.map { |mutant, index| mutant.with(id: index) }
		mutants = all.first(plan[:mutants].size)
		@ignored = all[plan[:mutants].size, plan[:ignored].size].zip(plan[:ignored].map(&:last))
		@reach = all.last(plan[:reach].size)
		@changed_tests = plan[:changed_tests]
		@reach_ids = {}
		@keys = keys(all)
		@cache = Quickdraw::Mutation::Cache.new(plan[:cache])
		@use_cache = options[:cache]
		@fingerprints = plan[:fingerprints]
		@cache_keys = {}
		# The ids of mutants whose outcomes came from the cache.
		@cached = {}
		@outcomes = []
		@rows = []
		@uncovered = []
		@missing = []
		@broken = []
		@jobs = []

		# Changed tests still have to kill something of their own, if only to fail.
		if mutants.empty? && @reach.empty? && @changed_tests.empty?
			where = " in the lines changed since #{options[:base] ? "this branched from #{options[:base]}" : 'the last commit'}" if options[:targets].empty?
			equivalent = ", besides #{pluralize(@ignored.size, 'mutant')} marked equivalent" if @ignored.any?
			return finish("Nothing to mutate#{where}#{equivalent}.", mutants, 0)
		end

		warn hint unless plan[:mapped]

		if plan[:test_files].empty? && mutants.any?
			@uncovered = mutants
			return finish("No tests run #{list(mutants.map { |mutant| relative(mutant.subject.path) }.uniq)}, so there’s nothing to kill their mutants.", mutants, 1)
		end

		run(mutants, plan[:test_files], processes: options[:processes] || plan[:processes].clamp(1, [mutants.size + @reach.size, 1].max))
	end

	# Without running anything. JSON is still a report, with the message on stderr.
	private def finish(message, mutants, status)
		@survived = []
		save_survivors

		if @format == "json"
			warn message
			report(mutants)
		else
			@io.puts message
		end

		status
	end

	private def run(mutants, test_files, processes:)
		runner = Quickdraw::Mutation::Runner.new(test_files.map { |path| File.expand_path(path) }, processes:, seed: @seed, matrix: @tracks_kills)

		begin
			mutate(runner, mutants, test_files)
		rescue Interrupt
			@interrupted = true
		end

		runner.stop
		report(mutants)
	rescue Quickdraw::Replay::BootFailed => error
		warn "Couldn’t boot to run tests: #{error.message}"
		1
	ensure
		runner&.stop
	end

	private def mutate(runner, mutants, test_files)
		groups = runner.start

		grouped, test_files = test_files.partition do |path|
			groups.any? { |_name, patterns, _gemfile| patterns.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) } }
		end

		warn "Skipping #{list(grouped)}, which #{grouped.one? ? 'is' : 'are'} in a group, and mutate doesn’t run groups yet." if grouped.any?

		subjects = [*mutants, *@reach].map(&:subject).uniq(&:id)
		baselines, @broken = runner.baseline(test_files.map { |path| File.expand_path(path) }, subjects)
		warn "#{list(@broken.map { |path| relative(path) })} failed to load, crashed or timed out, so #{@broken.one? ? 'its' : 'their'} tests don’t count." if @broken.any?

		failing = baselines.select { |baseline| baseline.status in "failed" | "errored" }
		if failing.any?
			warn "#{pluralize(failing.size, 'test')} failed without mutations, so #{failing.one? ? 'it doesn’t' : 'they don’t'} count: #{list(failing.map { |baseline| "#{relative(baseline.path)}:#{baseline.line}" })}"
		end

		covering = Hash.new { |hash, key| hash[key] = [] }

		baselines.each do |baseline|
			next unless baseline.status == "passed"

			baseline.lines.each { |id, lines| lines.each { |line| covering[[id, line]] << baseline } }
		end

		@missing = mutants.map(&:subject).uniq(&:id).reject { |subject| runner.traced.key?(subject.id) }

		mutants.each do |mutant|
			next unless runner.traced.key?(mutant.subject.id)

			tests = covering.fetch([mutant.subject.id, mutant.covering_line], nil)
			next @uncovered << mutant unless tests

			@jobs << job(mutant, tests)
		end

		if @unique_kills
			@unique_tests = changed_tests(baselines.select { |baseline| baseline.status == "passed" })
			changed = @unique_tests.to_h { |test| [[test.path, test.index], true] }

			# Only those a test this changes runs, to judge it by.
			@reach.each do |mutant|
				tests = covering.fetch([mutant.subject.id, mutant.covering_line], nil) if runner.traced.key?(mutant.subject.id)
				next unless tests&.any? { |test| changed.key?([test.path, test.index]) }

				@reach_ids[mutant.id] = true
				@jobs << job(mutant, tests)
			end
		end

		jobs = @jobs.reject { |job| from_cache(job) }

		runner.call(jobs) do |job, outcome, row|
			@outcomes << [job, outcome]
			@rows << [job, row] if @tracks_kills
			progress
		end
	end

	# Takes the job's outcome from an earlier run, if nothing it depends on has
	# changed since. With the matrix, only from a run that ran every test.
	private def from_cache(job)
		return false unless @use_cache

		cached = @cache.fetch(cache_key(job)) or return false
		outcome, row = cached
		# A row that didn't finish can't say which tests were the only ones to kill it.
		return false if @tracks_kills && !row&.fetch("complete")

		@cached[job.mutant.id] = true
		@outcomes << [job, outcome]
		@rows << [job, row] if @tracks_kills
		true
	end

	private def cache_key(job)
		@cache_keys[job.mutant.id] ||= begin
			files = job.tests.map { |test| relative(test.path) }.uniq.sort
			parts = [
				@keys.fetch(job.mutant.id),
				@fingerprints[:sources].fetch(relative(job.mutant.subject.path)),
				*files.map { |path| @fingerprints[:tests].fetch(path) },
				# Which of their tests ran it, as one that failed unmutated doesn't.
				*job.tests.map { |test| "#{relative(test.path)}:#{test.index}" }.sort,
				@fingerprints[:environment],
				@seed,
			]

			Quickdraw.stable_hash(parts.join("\0")).to_s(16)
		end
	end

	private def save_cache
		rows = @rows.to_h { |job, row| [job.mutant.id, row] }

		@outcomes.each do |job, outcome|
			@cache.store(cache_key(job), outcome, rows[job.mutant.id]) unless @cached.key?(job.mutant.id)
		end

		@cache.write
	rescue SystemCallError => error
		warn "Quickdraw couldn’t write #{Quickdraw::Mutation::Cache::PATH} (#{error.message})."
	end

	private def job(mutant, tests)
		tests = tests.sort_by(&:duration)
		Quickdraw::Mutation::Runner::Job.new(mutant:, tests:, seconds: (tests.sum(&:duration) * TIMEOUT_FACTOR) + TIMEOUT_MARGIN)
	end

	# The tests (Baselines) this adds or changes.
	private def changed_tests(baselines)
		baselines.select { |test| @changed_tests[relative(test.path)]&.include?(test.line) }
	end

	private def report(mutants)
		@io.print "\r\e[K" if progress?
		# Mutants run only to judge the tests this changes don't count.
		outcomes = @outcomes.reject { |job, _outcome| @reach_ids.key?(job.mutant.id) }
		@killed, rest = outcomes.partition { |_job, (status, *)| KILLED.include?(status) }
		@survived, @errors = rest.partition { |_job, (status, *)| status == "survived" }
		@survived.sort_by! { |job, _outcome| [job.mutant.subject.path, job.mutant.line, job.mutant.id] }
		tested = @killed.size + @survived.size
		@score = (100.0 * @killed.size / tested if tested > 0)
		@duration = now - @started_at
		@mutants = mutants
		@kill_matrix = Quickdraw::Mutation::KillMatrix.new(@rows) if @tracks_kills
		@not_unique = @kill_matrix.without_unique_kill(@unique_tests.reject(&:exempt)) if @unique_kills && @unique_tests
		@from_cache = outcomes.count { |job, _outcome| @cached.key?(job.mutant.id) }

		save_survivors
		save_cache

		case @format
		in "human" then report_for_people
		in "agent" then report_for_agents
		in "json" then report_json
		end

		annotate if Quickdraw::Reporters::GitHubActions.active? && @format != "json"

		exit_status
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
			snippet(mutant).each { |line| @io.puts "    #{line.start_with?('-') ? green(line) : red(line)}" }
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
	# ran it, are a command away (see #show), since agents pay for every line.
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

	private def report_for_agents
		@survived.first(SHOWN_SURVIVORS).each do |job, _outcome|
			mutant = job.mutant
			@io.puts "SURVIVED #{@keys.fetch(mutant.id)} #{relative(mutant.subject.path)}:#{mutant.line} #{mutant.subject.label}: #{mutant.description} (#{pluralize(job.tests.size, 'test')} ran it)"
		end

		@io.puts "and #{pluralize(@survived.size - SHOWN_SURVIVORS, 'more survivor')}" if @survived.size > SHOWN_SURVIVORS

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

		if @survived.any? && @saved
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
			"errors" => @errors.size,
			"missing" => missing_mutants,
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
			**({ "matrix" => matrix_json } if @matrix),
			**({ "unique_kills" => unique_kills_json } if @not_unique),
		})
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

		incomplete = @kill_matrix.incomplete
		if incomplete > 0
			@io.puts "#{yellow('!')} Not every test ran against #{pluralize(incomplete, 'mutant')}, since a test crashed, hung or didn’t load, so #{(incomplete == 1) ? 'its tests' : 'their tests'} can’t be blind or redundant."
			@io.puts
		end

		sections.any? || incomplete > 0
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

	# Ids that stay the same across runs while the method's code does, since
	# they don't include where the method is: the file, method, change, the
	# code it makes, its line within the method, and which of the identical
	# changes on that line it is. 48 bits, so ids rarely collide even across
	# hundreds of thousands of mutants.
	private def keys(mutants)
		seen = Hash.new(0)

		mutants.to_h do |mutant|
			# Without marks, so marking one doesn't change its neighbours' ids.
			identity = [relative(mutant.subject.path), mutant.subject.label, mutant.description, mutant.after.gsub(EQUIVALENT_MARK, "").strip, mutant.line - mutant.subject.line]
			seen[identity] += 1
			[mutant.id, Quickdraw.stable_hash([*identity, seen[identity]].join("\0")).to_s(16).rjust(16, "0")[0, 12]]
		end
	end

	# For --show: each survivor's id, line, change, and the tests that ran it.
	# JSON, since a checkout's files are untrusted, through a temporary file,
	# so it's never part of one run. Returns whether it was saved.
	private def save_survivors
		require "json"

		survivors = @survived.map do |job, _outcome|
			mutant = job.mutant

			{
				"id" => @keys.fetch(mutant.id),
				"heading" => "SURVIVED #{@keys.fetch(mutant.id)} #{relative(mutant.subject.path)}:#{mutant.line} #{mutant.subject.label}: #{mutant.description}",
				"change" => snippet(mutant),
				"tests" => job.tests.map { |test| "#{relative(test.path)}:#{test.line} #{test.name}" },
			}
		end

		begin
			Dir.mkdir(File.dirname(LAST_PATH))
		rescue Errno::EEXIST
			nil
		end

		temporary = "#{LAST_PATH}.#{Process.pid}"
		File.write(temporary, JSON.generate(survivors.map { |survivor| survivor.transform_values { |value| utf8(value) } }))
		File.rename(temporary, LAST_PATH)
		@saved = true
	rescue SystemCallError, JSON::GeneratorError => error
		warn "Quickdraw couldn’t write #{LAST_PATH} (#{error.message})."
		@saved = false
	end

	private def utf8(value)
		case value
		in String then Quickdraw.utf8(value)
		in Array then value.map { |item| utf8(item) }
		else value
		end
	end

	# A survivor from the last run in full, or every survivor a line each.
	private def show(key)
		require "json"

		survivors = begin
			JSON.parse(File.read(LAST_PATH, encoding: Encoding::UTF_8))
		rescue Errno::ENOENT, JSON::ParserError
			nil
		end

		unless survivors
			warn "No mutation run has been recorded here."
			return 1
		end

		if key == "all"
			survivors.each { |survivor| @io.puts survivor["heading"] }
			return 0
		end

		matches = survivors.select { |survivor| survivor["id"] == key }

		if matches.empty?
			warn "The last mutation run had no survivor #{key}."
			return 1
		end

		matches.each do |survivor|
			@io.puts survivor["heading"]
			survivor["change"].each { |line| @io.puts line }
			@io.puts "Tests that ran it and passed:"
			survivor["tests"].each { |test| @io.puts "- #{test}" }
		end

		0
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

		messages
	end

	private def missing_mutants
		ids = @missing.to_h { |subject| [subject.id, true] }
		@mutants.count { |mutant| ids.key?(mutant.subject.id) }
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
		outcomes = @outcomes.reject { |job, _outcome| @cached.key?(job.mutant.id) }
		ran = outcomes.size
		judging = outcomes.count { |job, _outcome| @reach_ids.key?(job.mutant.id) }
		judged = case judging
		in 0 then ""
		in ^ran then " to judge the tests this changes"
		else " (#{judging} to judge the tests this changes)"
		end

		seconds = format("%.2fs", @duration)
		return "All #{pluralize(@cached.size, 'mutant')} unchanged since an earlier run, so none ran, in #{seconds}" if ran == 0 && @cached.any?

		cached = ", and #{@cached.size} unchanged since an earlier run" if @cached.any?
		"#{pluralize(ran, 'mutant')}#{judged} in #{seconds}#{format(' (%.0f/s)', ran / @duration) if ran > 0}#{cached}"
	end

	private def format_score(score)
		"#{(score % 1).zero? ? score.to_i : format('%.1f', score)}%"
	end

	private def progress
		@io.print "\r\e[KMutants: #{@outcomes.size} of #{@jobs.size}" if progress?
	end

	private def progress?
		@format == "human" && @io.tty?
	end

	private def hint
		"No --coverage run has mapped which tests run which files, so running the mutated files’ tests by name. Run `#{Quickdraw::Reporters.command} --coverage` to map them."
	end

	# In a throwaway process. The mutants of the targets, those marked
	# equivalent with why, the test files that run them, and the default
	# worker count; or a String if they can't be found.
	#
	# With `unique_kills`, also the test files' lines this changes, and every
	# other mutant (reach) of the source files those test files run, so the
	# tests this adds or changes can be judged against all the code they run.
	private def prepare(targets, base, unique_kills:)
		sources = targets.empty? ? changed_sources(base) : given_sources(targets)
		return sources if String === sources

		warnings = []
		ignored = []
		mutants = sources.flat_map { |path, lines| mutants_of(path, lines, warnings, ignored) }
		changed_tests = {}
		reach = []

		if unique_kills
			begin
				changed = Quickdraw::Changes.lines(base:, deletions: true) || {}
			rescue Quickdraw::Changes::UnknownBase => error
				return error.message
			end

			changed.each do |path, lines|
				next unless path.end_with?(Quickdraw::Commands::Counterpart::TEST_SUFFIX) && File.file?(path)

				tests = changed_test_lines(path, lines)
				changed_tests[path] = tests if tests.any?
			end

			mutated = mutants.to_h { |mutant| [identity(mutant), true] }

			reach = sources_run_by(changed_tests.keys).flat_map do |path|
				mutants_of(path, nil, [], []).reject { |mutant| mutated.key?(identity(mutant)) }
			end
		end

		sources = [*mutants, *reach].map { |mutant| relative(mutant.subject.path) }.uniq
		test_files, mapped = covering_test_files(sources)
		test_files = (test_files + changed_tests.keys).uniq

		{
			mutants:,
			ignored:,
			reach:,
			changed_tests:,
			test_files:,
			mapped:,
			warnings:,
			processes: Quickdraw::Platform.non_blocking_cores,
			fingerprints: fingerprints(test_files, sources),
			cache: Quickdraw::Mutation::Cache.read,
		}
	end

	# The mutants of `path` that change `lines` (or any line, if nil), without
	# those marked equivalent, which go in `ignored` with why. Problems with
	# the marks go in `warnings`.
	private def mutants_of(path, lines, warnings, ignored)
		source = File.read(path, encoding: Encoding::UTF_8)
		mutants = Quickdraw::Mutation::Mutator.new(File.expand_path(path), source, relative_path: path).call(lines:)
		marks = equivalents(source)
		used = {}

		kept = mutants.reject do |mutant|
			line, text, reason = equivalent(mutant, marks)
			next false unless line

			used[[line, text]] = reason
			ignored << [mutant, reason || "no reason given"]
		end

		marks.each do |line, line_marks|
			next unless lines.nil? || lines.include?(line)

			line_marks.each do |text|
				description, reason = read_mark(text)
				reason = used[[line, text]] if used.key?([line, text])
				warnings << "#{path}:#{line} marks a mutant equivalent without saying why. Add a reason after --." if reason.nil?
				next if used.key?([line, text])

				renamed = " Mutants that empty or remove a literal now name it, as in “\"cm\" → \"\"” or “removed b: 1”." if description in "emptied the string" | "emptied the array" | "emptied the hash" | "removed an element" | "removed a pair"
				warnings << "#{path}:#{line} marks #{description ? "“#{description}”" : 'mutants'} equivalent, but no mutant there matches.#{renamed}"
			end
		end

		kept
	rescue SyntaxError => error
		warnings << "Couldn’t parse #{path}: #{error.message}"
		[]
	end

	private def identity(mutant)
		[mutant.subject.path, mutant.line, mutant.last_line, mutant.description, mutant.after]
	end

	# The project's source files that `test_paths` run, from the coverage
	# map, or else, for a test file it hasn't mapped (one this adds, say),
	# its counterpart by name.
	private def sources_run_by(test_paths)
		return [] if test_paths.empty?

		covered = covered_sources(test_paths)
		counterpart = Quickdraw::Commands::Counterpart.new
		sources = test_paths.flat_map { |path| covered.fetch(path) { [counterpart.find(path)].compact } }
		sources.uniq.select { |path| source?(path) && File.file?(path) }
	end

	# { test path => source files it ran in its last --coverage run }, for
	# those of `test_paths` the coverage map has.
	private def covered_sources(test_paths)
		return {} if test_paths.empty?

		history = Quickdraw::History.new(Quickdraw::CLI::HISTORY_PATH, read_only: true) if Quickdraw::History.exist?(Quickdraw::CLI::HISTORY_PATH)
		history ? history.sources_covered_by(test_paths) : {}
	rescue Quickdraw::History::Error
		{}
	ensure
		history&.close
	end

	# What a mutant's outcome depends on, besides the mutant itself and its
	# file: each test file with the sources it ran in its last --coverage run,
	# and the bundle, config, what booting it ran, and Quickdraw. A mutant
	# whose fingerprint is the same as when it last ran has the same outcome
	# (see Cache).
	private def fingerprints(test_files, source_files)
		require "digest"
		require "quickdraw/version"
		digests = Hash.new { |hash, path| hash[path] = File.file?(path) ? Digest::SHA256.file(path).hexdigest : "none" }
		covered = covered_sources([*test_files, Quickdraw::History::BOOT])
		digest = -> (paths) { Digest::SHA256.hexdigest(paths.uniq.sort.map { |path| "#{path}\0#{digests[path]}" }.join("\0")) }

		# Helpers beside the tests, such as test/support/, which coverage doesn't
		# map, since it leaves out test directories.
		helpers = test_files.map { |path| path.split("/").first }.uniq.flat_map do |directory|
			File.directory?(directory) ? Dir.glob("#{directory}/**/*.rb").reject { |path| path.end_with?(Quickdraw::Commands::Counterpart::TEST_SUFFIX) } : []
		end

		# What a test file the coverage map doesn't have runs is unknown, so
		# every source in the project, which any change invalidates.
		every_source = nil
		unmapped = lambda do
			# Not into vendor/ and the like, which can be huge.
			every_source ||= Dir.children(".").reject { |name| source?("#{name}/x.rb") == false && File.directory?(name) }.flat_map do |name|
				File.directory?(name) ? Dir.glob("#{name}/**/*.rb") : [name]
			end.select { |path| source?(path) }
		end
		runtime = [RUBY_ENGINE, RUBY_ENGINE_VERSION, RUBY_VERSION, RUBY_PLATFORM, Quickdraw::VERSION].join(" ")

		{
			tests: test_files.to_h { |path| [path, digest.([path, *covered.fetch(path) { unmapped.() }])] },
			sources: source_files.to_h { |path| [path, digests[path]] },
			environment: "#{digest.([*Quickdraw::Mutation::Cache::ENVIRONMENT, *covered.fetch(Quickdraw::History::BOOT, []), *helpers])} #{runtime}",
		}
	end

	# Where each `test` call with a changed line starts its block, which is
	# the line a test is defined at.
	private def changed_test_lines(path, lines)
		require "prism"
		starts = []
		nodes = [Prism.parse_file(path).value]

		while (node = nodes.pop)
			if node in Prism::CallNode[name: :test | :fuzz, receiver: nil, block: Prism::BlockNode => block]
				starts << block.location.start_line if lines.any? { |line| line.between?(node.location.start_line, node.location.end_line) }
			end

			nodes.concat(node.compact_child_nodes)
		end

		starts
	end

	EQUIVALENT = /\A#\s*quickdraw:equivalent\b(?<text>.*)\z/
	EQUIVALENT_MARK = /[ \t]*#\s*quickdraw:equivalent\b.*$/

	# { line => [[description or nil, reason or nil]] }, from comments such as
	# `# quickdraw:equivalent > → >= -- the cap below makes it the same`.
	# Without a description, it's every mutant on the line.
	private def equivalents(source)
		Prism.parse_comments(source).each_with_object({}) do |comment, marks|
			match = EQUIVALENT.match(comment.slice.strip) or next
			(marks[comment.location.start_line] ||= []) << match[:text].strip
		end
	end

	# A mark's text as [description or nil, reason or nil], for `mutant`, whose
	# description may itself contain " -- " (or, without one, at the first).
	private def read_mark(text, description = nil)
		if description && (text == description || text.start_with?("#{description} "))
			reason = text.delete_prefix(description)[/\A\s+--\s*(.*)\z/, 1]
			return [description, reason.to_s.empty? ? nil : reason] if text == description || reason
		end

		marked, reason = text.split(/(?:\A|\s+)--\s*/, 2)
		[(marked unless marked.to_s.empty?), (reason unless reason.to_s.empty?)]
	end

	# The mark on one of `mutant`'s lines that covers it, as [line, description, reason], or nil.
	# [line, text, reason] for the mark that covers `mutant`, or nil.
	private def equivalent(mutant, marks)
		mutant.line.upto(mutant.last_line) do |line|
			marks.fetch(line, []).each do |text|
				description, reason = read_mark(text, mutant.description)
				return [line, text, reason] if description.nil? || description == mutant.description
			end
		end

		nil
	end

	# { path => changed lines } for the project's own Ruby files.
	private def changed_sources(base)
		changes = Quickdraw::Changes.lines(base:) or return "mutate needs a git repository to see what’s changed, or files to mutate."
		changes.select { |path, _lines| source?(path) && File.file?(path) }
	rescue Quickdraw::Changes::UnknownBase => error
		error.message
	end

	# { path => lines, or nil for all of them }
	private def given_sources(targets)
		targets.each_with_object({}) do |target, sources|
			match = SPECIFICATION.match(target)
			path = match[:path].delete_prefix("#{Dir.pwd}/").delete_prefix("./")

			if File.directory?(path)
				files = Dir.glob("**/*.rb", base: path).map { |file| File.join(path, file).delete_prefix("./") }
				files.select { |file| source?(file) }.each { |file| sources[file] = nil }
			elsif File.file?(path)
				lines = (Integer(match[:first], 10)..Integer(match[:last] || match[:first], 10)).to_a if match[:first]
				sources[path] = lines && (sources.key?(path) ? sources[path]&.union(lines) : lines)
			else
				return "#{path} doesn’t exist."
			end
		end
	end

	private def source?(path)
		path.end_with?(".rb") && !Quickdraw::CoverageCollector::EXCLUDED.match?(path) && path != Quickdraw::Loader::CONFIG_PATH
	end

	# The test files that run any of `sources` in the coverage map, all of them
	# if a source only runs while config boots, and each source's counterpart.
	# Then whether there was a map.
	private def covering_test_files(sources)
		covering, booted = coverage_map(sources)

		test_files = if booted&.any?
			Dir.glob(Quickdraw::CLI::DEFAULT_PATTERN).grep_v(Quickdraw::CLI::IGNORED_DIRECTORIES)
		else
			counterpart = Quickdraw::Commands::Counterpart.new
			[*covering, *sources.filter_map { |path| counterpart.find(path) }]
		end

		[test_files.uniq.select { |path| File.file?(path) }, !covering.nil?]
	end

	# See History#tests_covering. Nil without a map, or if it can't be read.
	private def coverage_map(sources)
		return unless Quickdraw::History.exist?(Quickdraw::CLI::HISTORY_PATH)

		history = Quickdraw::History.new(Quickdraw::CLI::HISTORY_PATH, read_only: true)
		history.tests_covering(sources)
	rescue Quickdraw::History::Error => error
		warn "Couldn’t read the run history: #{error.message}"
		nil
	ensure
		history&.close
	end

	private def parse
		options = { targets: [], processes: nil, threshold: 100.0, format: nil, seed: DEFAULT_SEED, matrix: false, show: nil, base: nil, unique_kills: false, cache: true }

		until @args.empty?
			argument = @args.shift

			case argument
			in "--"
				options[:targets].concat(@args)
				@args.clear
			in "-p" | "--processes"
				options[:processes] = Integer(@args.shift.to_s, 10, exception: false)
				return usage("#{argument} needs a number of workers, as in #{argument} 4.") unless options[:processes]&.positive?
			in "-s" | "--seed"
				options[:seed] = Integer(@args.shift.to_s, 10, exception: false)
				return usage("#{argument} needs a number, as in #{argument} 1234.") unless options[:seed]&.between?(0, Quickdraw::CLI::MAX_SEED)
			in "--threshold"
				options[:threshold] = Float(@args.shift.to_s, exception: false)
				return usage("--threshold needs a percentage, as in --threshold 80.") unless options[:threshold]&.between?(0, 100)
			in "--base"
				options[:base] = @args.shift
				return usage("--base needs a git ref, as in --base origin/main.") unless options[:base] && !options[:base].start_with?("-")
			in "--show"
				options[:show] = @args.shift
				return usage("--show needs a survivor's id, from the last run, or all.") unless options[:show]
			in "--matrix"
				options[:matrix] = true
			in "--unique-kills"
				options[:unique_kills] = true
			in "--no-cache"
				options[:cache] = false
			in "--format"
				options[:format] = @args.shift
				return usage("--format needs one of #{FORMATS.join(', ')}.") unless FORMATS.include?(options[:format])
			in "-h" | "--help"
				@io.puts help
				return 0
			in /\A-/
				return usage("Unknown option #{argument}.")
			else
				options[:targets] << argument
			end
		end

		return usage("--base mutates the lines changed since a ref, so it can’t be used with files.") if options[:base] && options[:targets].any?

		# In a pull request on GitHub Actions, what it changes.
		options[:base] ||= "origin/#{ENV['GITHUB_BASE_REF']}" if options[:targets].empty? && !ENV["GITHUB_BASE_REF"].to_s.empty?
		options
	end

	private def usage(message)
		warn message
		warn help
		2
	end

	private def help
		<<~TEXT
			Usage: #{Quickdraw::Reporters.command} mutate [PATH[:LINE[-LINE]] …] [options]

			Mutates the lines changed since the last commit, or the files, directories and lines given,
			and runs the tests that run each mutant. Lists the mutants no test failed for.

			        --base REF        Mutate the lines changed since this branched from REF, as in a pull
			                          request (on GitHub Actions, the pull request's base, by default)
			    -p, --processes N     Run N workers
			    -s, --seed N          Seed rand in tests with N (default #{DEFAULT_SEED}), the same for every mutant
			        --threshold PERCENT
			                          Fail if fewer than PERCENT of mutants are killed (default 100)
			        --matrix          Run every test against each mutant, and list tests that kill none
			                          (blind) and tests whose kills others also make (redundant)
			        --unique-kills    Fail if a test this changes isn't the only one to kill some mutant of the
			                          code it runs (a test marked `mutation: false` is exempt). Implies --matrix
			        --no-cache        Run every mutant, rather than reuse the outcome of those whose method,
			                          tests and the code their tests run haven't changed since an earlier run
			        --format FORMAT   human, agent or json
			        --show ID         Show a survivor from the last run: its change and the tests that ran it
			                          (all lists every survivor)
		TEXT
	end

	private def list(items)
		items.first(3).join(", ") + ((items.size > 3) ? " and #{items.size - 3} more" : "")
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
