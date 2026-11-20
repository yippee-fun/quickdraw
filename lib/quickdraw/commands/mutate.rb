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
		@matrix = options[:matrix]

		# Prism, sqlite3 and etc load in a throwaway process, so they can't reach workers.
		plan = Quickdraw.isolate { prepare(options[:targets]) }

		if String === plan
			warn plan
			return 2
		end

		plan[:warnings].each { |message| warn message }
		mutants = plan[:mutants].each_with_index.map { |mutant, index| mutant.with(id: index) }
		@keys = keys(mutants)
		@outcomes = []
		@rows = []
		@uncovered = []
		@missing = []
		@broken = []
		@jobs = []

		if mutants.empty?
			return finish("Nothing to mutate#{' in the lines changed since the last commit' if options[:targets].empty?}.", mutants, 0)
		end

		warn hint unless plan[:mapped]

		if plan[:test_files].empty?
			@uncovered = mutants
			return finish("No tests run #{list(mutants.map { |mutant| relative(mutant.subject.path) }.uniq)}, so there’s nothing to kill their mutants.", mutants, 1)
		end

		run(mutants, plan[:test_files], processes: options[:processes] || plan[:processes].clamp(1, mutants.size))
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
		runner = Quickdraw::Mutation::Runner.new(test_files.map { |path| File.expand_path(path) }, processes:, seed: @seed, matrix: @matrix)

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

		subjects = mutants.map(&:subject).uniq(&:id)
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

		@missing = subjects.reject { |subject| runner.traced.key?(subject.id) }

		mutants.each do |mutant|
			next unless runner.traced.key?(mutant.subject.id)

			tests = covering.fetch([mutant.subject.id, mutant.covering_line], nil)
			next @uncovered << mutant unless tests

			tests = tests.sort_by(&:duration)
			@jobs << Quickdraw::Mutation::Runner::Job.new(mutant:, tests:, seconds: (tests.sum(&:duration) * TIMEOUT_FACTOR) + TIMEOUT_MARGIN)
		end

		runner.call(@jobs) do |job, outcome, row|
			@outcomes << [job, outcome]
			@rows << [job, row] if @matrix
			progress
		end
	end

	private def report(mutants)
		@io.print "\r\e[K" if progress?
		@killed, rest = @outcomes.partition { |_job, (status, *)| KILLED.include?(status) }
		@survived, @errors = rest.partition { |_job, (status, *)| status == "survived" }
		@survived.sort_by! { |job, _outcome| [job.mutant.subject.path, job.mutant.line, job.mutant.id] }
		tested = @killed.size + @survived.size
		@score = (100.0 * @killed.size / tested if tested > 0)
		@duration = now - @started_at
		@mutants = mutants
		@kill_matrix = Quickdraw::Mutation::KillMatrix.new(@rows) if @matrix

		save_survivors

		case @format
		in "human" then report_for_people
		in "agent" then report_for_agents
		in "json" then report_json
		end

		exit_status
	end

	# A run that couldn't run everything it should have isn't a pass, whatever its score.
	private def exit_status
		if @interrupted then 130
		elsif @score && @score < @threshold then 1
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

		problems.each { |problem| @io.puts "#{yellow('!')} #{problem}" }
		print_kill_matrix if @kill_matrix

		counts = if @score
			["#{format_score(@score)} mutation score", "#{@killed.size} killed", (red("#{@survived.size} survived") if @survived.any?)]
		else
			["No mutants ran"]
		end

		counts << yellow("#{@uncovered.size} on lines no test runs") if @uncovered.any?
		badge, background = (exit_status == 0) ? ["PASSED", 42] : ["FAILED", 41]
		@io.puts if problems.any? || @survived.empty?
		@io.puts "#{label(badge, background)} #{counts.compact.join(dim(' · '))}"
		@io.puts "#{beside_label(badge)}#{dim(rate)}"
	end

	# A line per survivor, with its id. Each one's change, and the tests that
	# ran it, are a command away (see #show), since agents pay for every line.
	private def report_for_agents
		@survived.first(SHOWN_SURVIVORS).each do |job, _outcome|
			mutant = job.mutant
			@io.puts "SURVIVED #{@keys.fetch(mutant.id)} #{relative(mutant.subject.path)}:#{mutant.line} #{mutant.subject.label}: #{mutant.description} (#{pluralize(job.tests.size, 'test')} ran it)"
		end

		@io.puts "and #{pluralize(@survived.size - SHOWN_SURVIVORS, 'more survivor')}" if @survived.size > SHOWN_SURVIVORS

		problems.each { |problem| @io.puts problem }

		if @kill_matrix
			matrix_entries(@kill_matrix.blind).each { |entry| @io.puts "BLIND: #{relative(entry.test.path)}:#{entry.test.line} #{entry.test.name} ran against #{pluralize(entry.count, 'mutant')} and killed none" }
			matrix_entries(@kill_matrix.redundant).each { |entry| @io.puts "REDUNDANT: #{relative(entry.test.path)}:#{entry.test.line} #{entry.test.name}. Another test also killed each mutant it killed (#{entry.count})" }
		end
		@io.puts "NOT COVERED: #{pluralize(@uncovered.size, 'mutant')} on lines no test runs: #{uncovered_lines}" if @uncovered.any?

		if @score
			@io.puts "MUTATION SCORE: #{format_score(@score)} (#{@killed.size} of #{@killed.size + @survived.size} killed#{", #{@survived.size} survived" if @survived.any?}). #{rate}"
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
			"errors" => @errors.size,
			"missing" => missing_mutants,
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
			**({ "matrix" => matrix_json } if @kill_matrix),
		})
	end

	# Tests that ran mutants and killed none, then tests whose kills others made too.
	private def print_kill_matrix
		[
			["Blind tests", "ran against mutants and killed none", @kill_matrix.blind, "ran against"],
			["Redundant tests", "every mutant they killed, another test killed too, so each could go, one at a time", @kill_matrix.redundant, "killed"],
		].each do |title, explanation, entries, counted|
			next if entries.empty?

			@io.puts "#{bold(title)} #{dim(explanation)}"
			matrix_entries(entries).each do |entry|
				@io.puts "  #{relative(entry.test.path)}:#{entry.test.line} #{entry.test.name}  #{dim("#{counted} #{pluralize(entry.count, 'mutant')}")}"
			end
			@io.puts "  #{dim("and #{entries.size - SHOWN_MATRIX_TESTS} more")}" if entries.size > SHOWN_MATRIX_TESTS
			@io.puts
		end

		if (incomplete = @kill_matrix.incomplete) > 0
			@io.puts "#{yellow('!')} Not every test ran against #{pluralize(incomplete, 'mutant')}, since a test crashed, hung or didn’t load, so #{(incomplete == 1) ? 'its tests' : 'their tests'} can’t be blind or redundant."
			@io.puts
		end
	end

	private def matrix_entries(entries) = entries.first(SHOWN_MATRIX_TESTS)

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
			identity = [relative(mutant.subject.path), mutant.subject.label, mutant.description, mutant.after.strip, mutant.line - mutant.subject.line]
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

	private def rate
		ran = @outcomes.size
		"#{pluralize(ran, 'mutant')} in #{format('%.2f', @duration)}s#{format(' (%.0f/s)', ran / @duration) if ran > 0}"
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

	# In a throwaway process. The mutants of the targets, the test files that
	# run them, and the default worker count; or a String if they can't be found.
	private def prepare(targets)
		sources = targets.empty? ? changed_sources : given_sources(targets)
		return sources if String === sources

		warnings = []

		mutants = sources.flat_map do |path, lines|
			Quickdraw::Mutation::Mutator.new(File.expand_path(path), File.read(path, encoding: Encoding::UTF_8), relative_path: path).call(lines:)
		rescue SyntaxError => error
			warnings << "Couldn’t parse #{path}: #{error.message}"
			[]
		end

		test_files, mapped = covering_test_files(mutants.map { |mutant| relative(mutant.subject.path) }.uniq)
		{ mutants:, test_files:, mapped:, warnings:, processes: Quickdraw::Platform.non_blocking_cores }
	end

	# { path => changed lines } for the project's own Ruby files.
	private def changed_sources
		changes = Quickdraw::Changes.lines or return "mutate needs a git repository to see what’s changed, or files to mutate."
		changes.select { |path, _lines| source?(path) && File.file?(path) }
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
		options = { targets: [], processes: nil, threshold: 100.0, format: nil, seed: DEFAULT_SEED, matrix: false, show: nil }

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
			in "--show"
				options[:show] = @args.shift
				return usage("--show needs a survivor's id, from the last run, or all.") unless options[:show]
			in "--matrix"
				options[:matrix] = true
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

			    -p, --processes N     Run N workers
			    -s, --seed N          Seed rand in tests with N (default #{DEFAULT_SEED}), the same for every mutant
			        --threshold PERCENT
			                          Fail if fewer than PERCENT of mutants are killed (default 100)
			        --matrix          Run every test against each mutant, and list tests that kill none
			                          (blind) and tests whose kills others also make (redundant)
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
