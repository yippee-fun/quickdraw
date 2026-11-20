# frozen_string_literal: true

# Mutation testing: changes the code in methods in small ways (mutants), and
# runs the tests that run each change to see whether any fails. A mutant no
# test notices (a survivor) is code the tests run but don't check.
#
# Mutates the lines changed since the last commit, or the files and lines
# given. Mutants are applied in forked workers, never on disk (see Runner).
# What to mutate comes from a Planner, and what the run found is a Report.
class Quickdraw::Commands::Mutate
	include Quickdraw::Commands::Output
	include Quickdraw::Reporters::Formatting

	FORMATS = ["human", "agent", "json"].freeze

	# A mutant's tests may take this many times as long as they did unmutated,
	# plus TIMEOUT_MARGIN seconds, before it counts as looping forever, which kills it.
	TIMEOUT_FACTOR = 3
	TIMEOUT_MARGIN = 0.5

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

		return Quickdraw::Mutation::Survivors.show(options[:show], io: @io) if options[:show]

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
		@plan = Quickdraw.isolate do
			Quickdraw::Mutation::Planner.new(options[:targets], base: options[:base], unique_kills: @unique_kills).call
		rescue Quickdraw::Mutation::Planner::Error => error
			error.message
		end

		if String === @plan
			warn @plan
			return 2
		end

		@plan.warnings.each { |message| warn message }
		@reach_ids = {}
		@cache = Quickdraw::Mutation::Cache.new(@plan.cache)
		@use_cache = options[:cache]
		@cache_keys = {}
		# The ids of mutants whose outcomes came from the cache.
		@cached = {}
		@outcomes = []
		@rows = []
		@uncovered = []
		@missing = []
		@broken = []
		@jobs = []

		mutants = @plan.mutants

		if @plan.empty?
			where = " in the lines changed since #{options[:base] ? "this branched from #{options[:base]}" : 'the last commit'}" if options[:targets].empty?
			equivalent = ", besides #{pluralize(@plan.ignored.size, 'mutant')} marked equivalent" if @plan.ignored.any?
			return finish("Nothing to mutate#{where}#{equivalent}.", 0)
		end

		warn hint unless @plan.mapped

		if @plan.test_files.empty? && mutants.any?
			@uncovered = mutants
			return finish("No tests run #{list(mutants.map { |mutant| relative(mutant.subject.path) }.uniq)}, so there’s nothing to kill their mutants.", 1)
		end

		run(processes: options[:processes] || @plan.processes.clamp(1, [mutants.size + @plan.reach.size, 1].max))
	end

	# Without running anything. JSON is still a report, with the message on stderr.
	private def finish(message, status)
		Quickdraw::Mutation::Survivors.save([])

		if @format == "json"
			warn message
			report
		else
			@io.puts message
		end

		status
	end

	private def run(processes:)
		test_files = @plan.test_files
		runner = Quickdraw::Mutation::Runner.new(test_files.map { |path| File.expand_path(path) }, processes:, seed: @seed, matrix: @tracks_kills)

		begin
			mutate(runner, test_files)
		rescue Interrupt
			@interrupted = true
		end

		runner.stop
		report
	rescue Quickdraw::Replay::BootFailed => error
		warn "Couldn’t boot to run tests: #{error.message}"
		1
	ensure
		runner&.stop
	end

	private def mutate(runner, test_files)
		groups = runner.start

		grouped, test_files = test_files.partition do |path|
			groups.any? { |_name, patterns, _gemfile| patterns.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) } }
		end

		warn "Skipping #{list(grouped)}, which #{grouped.one? ? 'is' : 'are'} in a group, and mutate doesn’t run groups yet." if grouped.any?

		mutants = @plan.mutants
		subjects = [*mutants, *@plan.reach].map(&:subject).uniq(&:id)
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
			judged = @unique_tests.reject(&:exempt).to_h { |test| [[test.path, test.index], true] }

			# Which could have judged them.
			@missing |= subjects.reject { |subject| runner.traced.key?(subject.id) } if judged.any?

			# Only those a test this changes and doesn't exempt runs, to judge it by.
			@plan.reach.each do |mutant|
				tests = covering.fetch([mutant.subject.id, mutant.covering_line], nil) if runner.traced.key?(mutant.subject.id)
				next unless tests&.any? { |test| judged.key?([test.path, test.index]) }

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
			fingerprints = @plan.fingerprints
			files = job.tests.map { |test| relative(test.path) }.uniq.sort
			parts = [
				@plan.keys.fetch(job.mutant.id),
				fingerprints[:sources].fetch(relative(job.mutant.subject.path)),
				*files.map { |path| fingerprints[:tests].fetch(path) },
				# Which of their tests ran it, as one that failed unmutated doesn't.
				*job.tests.map { |test| "#{relative(test.path)}:#{test.index}" }.sort,
				fingerprints[:environment],
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
		baselines.select { |test| @plan.changed_tests[relative(test.path)]&.include?(test.line) }
	end

	private def report
		@io.print "\r\e[K" if progress?

		report = Quickdraw::Mutation::Report.new(
			@io,
			@plan,
			format: @format,
			threshold: @threshold,
			matrix: @matrix,
			outcomes: @outcomes,
			rows: @rows,
			jobs: @jobs,
			reach_ids: @reach_ids,
			cached: @cached,
			uncovered: @uncovered,
			missing: @missing,
			broken: @broken,
			unique_tests: @unique_tests,
			interrupted: @interrupted,
			duration: now - @started_at,
		)

		survivors_saved = Quickdraw::Mutation::Survivors.save(report.survivors)
		save_cache
		report.call(survivors_saved:)
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
			                          code it runs (a test marked `mutation: false` is exempt). Runs every test
			                          against each mutant, as --matrix does
			        --no-cache        Run every mutant, rather than reuse the outcome of those whose method,
			                          tests and the code their tests run haven't changed since an earlier run
			        --format FORMAT   human, agent or json
			        --show ID         Show a survivor from the last run: its change and the tests that ran it
			                          (all lists every survivor)
		TEXT
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
