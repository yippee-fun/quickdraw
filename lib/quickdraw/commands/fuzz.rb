# frozen_string_literal: true

# Fuzzing: runs tests' properties for a time rather than a number of cases,
# keeping the cases that reach new code and changing them to make more (see
# Quickdraw::Fuzz), on every worker at once. Fuzzes the tests `fuzz` defines
# in the files and directories given, or in every test file, and the tests
# given by line, which can be any test that checks a property.
#
# What it finds is saved with the property's failing cases, so test runs
# replay it first until it passes.
class Quickdraw::Commands::Fuzz
	include Quickdraw::Commands::Output
	include Quickdraw::Reporters::Formatting

	FORMATS = ["human", "agent", "json"].freeze
	SPECIFICATION = /\A(?<path>.+?)(?::(?<line>\d+))?\z/
	DEFAULT_SECONDS = 30
	DEFAULT_TIMEOUT = 1

	# Files in a directory that don't mention it can't define fuzz tests, so
	# they aren't loaded.
	MENTION = /\bfuzz\b/

	BADGES = Quickdraw.deep_freeze({ "failed" => ["FAILED", 41], "errored" => ["ERRORED", 41], "crashed" => ["CRASHED", 45], "hung" => ["HUNG", 43] })

	# What to fuzz in a test file: the tests at `lines`, and the tests fuzz
	# defines if `fuzz_tests`.
	Selection = Data.define(:lines, :fuzz_tests)

	# A test being fuzzed, and what's come of it across workers.
	class Target
		def initialize(path, test, started_at)
			@path = path
			@test = test
			@started_at = started_at
			@cases = 0
			@edges = {}
			@features = {}
			@corpus = 0
			@methods = 0
			@timeline = []
			@findings = {}
			@duration = nil
		end

		attr_reader :path, :test, :started_at, :cases, :corpus, :methods, :timeline, :duration

		def edges = @edges.size

		# Edges with their counts' buckets (see Fuzz::Edges#take).
		def features = @features.size

		# The simplest of each way it failed.
		def findings = @findings.values

		def started(methods)
			@methods = [@methods, methods].max
		end

		# Records when it reached more edges, as [seconds, edges], for the report.
		def progress(cases, features, corpus, now)
			@cases += cases
			before = @edges.size

			features.each do |feature|
				@features[feature] = true
				@edges[feature >> 3] = true
			end

			@timeline << [now - @started_at, @edges.size] if @edges.size > before
			@corpus = [@corpus, corpus].max
		end

		def found(finding)
			signature = finding.failure.signature
			existing = @findings[signature]
			# A shrunk finding follows the one found, and is never longer.
			@findings[signature] = finding if existing.nil? || finding.choices.size <= existing.choices.size
		end

		def finish(now)
			@duration = now - @started_at
		end
	end

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

		return forget(options[:targets]) if options[:forget]

		unless Process.respond_to?(:fork)
			warn "fuzz needs fork, which this platform doesn’t support."
			return 2
		end

		@format = options[:format] || (Quickdraw::Reporters.agent? ? "agent" : "human")
		@seconds = options[:seconds]
		@timeout = options[:timeout]
		@seed = options[:seed] || rand(Quickdraw::CLI::MAX_SEED)
		@targets = []
		@problems = []

		files = case select(options[:targets])
		in String => message
			warn message
			return 2
		in Hash => files then files
		end

		@processes = options[:processes] || Quickdraw::Platform.non_blocking_cores
		return report if files.empty?

		begin
			runner = Quickdraw::Fuzz::Runner.new(files.keys.map { |path| File.expand_path(path) }, processes: @processes, seed: @seed)
			fuzz(runner, files)
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

	private def fuzz(runner, files)
		groups = runner.start

		grouped, paths = files.keys.partition do |path|
			groups.any? { |_name, patterns, _gemfile| patterns.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) } }
		end

		warn "Skipping #{list(grouped)}, which #{grouped.one? ? 'is' : 'are'} in a group, and fuzz doesn’t run groups yet." if grouped.any?

		paths.each do |path|
			absolute = File.expand_path(path)
			next @problems << "#{path} failed to load." unless (tests = runner.load(absolute))

			selection = files[path]
			filter = Quickdraw::Filter.new(lines: { absolute => selection.lines })
			filter.unmatched_lines(absolute, tests).each { |line| @problems << "There’s no test at #{path}:#{line}." }
			given = selection.lines.empty? ? [] : filter.selected_indices(absolute, tests)

			(selection.fuzz_tests ? tests.each_index : given).each do |index|
				fuzz_test(runner, path, tests[index], index, explicit: given.include?(index))
			end
		end
	end

	private def fuzz_test(runner, path, test, index, explicit:)
		target = Target.new(path, test, now)

		begin
			outcomes = runner.call(File.expand_path(path), index, seconds: @seconds, timeout: @timeout, seed: @seed, explicit:) do |message|
				case message
				in [:fuzz_started, methods]
					@targets << target unless @targets.include?(target)
					target.started(methods)
				in [:fuzz_progress, cases, features, corpus]
					target.progress(cases, features, corpus, now)
					progress(target)
				in [:fuzz_finding, finding]
					target.found(finding)
				end
			end
		ensure
			# Interrupted too.
			target.finish(now)
		end

		name = "#{name_of(test)} (#{path}:#{test['line']})"

		outcomes.uniq.each do |outcome|
			case outcome
			in ["fuzzed"] | ["untargeted"] | ["unloaded"] then nil
			in ["fuzzed", error] then @problems << "#{name} failed after fuzzing its first property: #{error_summary(error)}"
			in ["unchecked"] then @problems << "#{name} checks no property, so there’s nothing to fuzz."
			in ["errored", error] then @problems << "#{name} failed before fuzzing: #{error_summary(error)}"
			in ["lost"] then @problems << "A worker exited while fuzzing #{name}."
			end
		end
	end

	private def report
		@io.print "\r\e[K" if progress?
		@duration = now - @started_at
		save_findings

		case @format
		in "human" then report_for_people
		in "agent" then report_for_agents
		in "json" then report_json
		end

		exit_status
	end

	# With the property's failing cases, which test runs replay first.
	private def save_findings
		@targets.each do |target|
			target.findings.each { |finding| Quickdraw::Property.remember(finding.key, finding.choices) }
		end
	end

	private def exit_status
		if @interrupted then 130
		elsif findings.any? || @problems.any? || @targets.empty? then 1
		else 0
		end
	end

	private def findings
		@targets.flat_map { |target| target.findings.map { |finding| [target, finding] } }
	end

	private def report_for_people
		findings.each do |target, finding|
			text, background = BADGES.fetch(finding.kind)
			@io.puts "#{label(text, background)} #{test_heading(target.path, target.test['line'], target.test['class_name'], target.test['description'])}"
			@io.puts
			details(finding).each { |line| @io.puts "    #{line}" }
			@io.puts
			@io.puts "  #{bold(found(finding))}"
			@io.puts
			@io.puts indent(finding.input, 4)
			@io.puts
		end

		@problems.each { |problem| @io.puts "#{yellow('!')} #{problem}" }
		@io.puts "No tests to fuzz. Define one with fuzz, or give a test that checks a property by line." if @targets.empty? && @problems.empty?

		@targets.each do |target|
			@io.puts "#{bold(name_of(target.test))}  #{dim("#{target.path}:#{target.test['line']}")}"
			@io.puts "  #{dim(summary(target))}"
			@io.puts "  #{dim(edges_over_time(target))}" if target.timeline.any?
		end

		badge, background = (exit_status == 0) ? ["PASSED", 42] : ["FAILED", 41]
		counts = ["#{pluralize(@targets.size, 'test')} fuzzed", (red(pluralize(findings.size, "finding")) if findings.any?)]
		@io.puts
		@io.puts "#{label(badge, background)} #{counts.compact.join(dim(' · '))}"
		@io.puts "#{beside_label(badge)}#{dim(rate)}"
	end

	private def report_for_agents
		findings.each do |target, finding|
			@io.puts "#{finding.kind.upcase}: #{target.path}:#{target.test['line']} #{name_of(target.test)}. #{found(finding)}:"
			@io.puts finding.input
			details(finding).each { |line| @io.puts line }
			@io.puts
		end

		@problems.each { |problem| @io.puts problem }
		@io.puts "NO TESTS TO FUZZ. Define one with fuzz, or give a test that checks a property by line." if @targets.empty? && @problems.empty?

		@targets.each do |target|
			@io.puts "FUZZED: #{target.path}:#{target.test['line']} #{name_of(target.test)}: #{summary(target)}. #{edges_over_time(target)}"
		end

		@io.puts "#{pluralize(findings.size, 'finding')}, saved to replay first in test runs. #{rate}" if findings.any?
	end

	private def report_json
		require "json"

		@io.puts JSON.generate({
			"seed" => @seed,
			"seconds" => @seconds,
			"workers" => @processes,
			"duration" => @duration.round(3),
			"interrupted" => !!@interrupted,
			"problems" => @problems,
			"tests" => @targets.map do |target|
				{
					"path" => target.path,
					"line" => target.test["line"],
					"name" => name_of(target.test),
					"duration" => target.duration&.round(3),
					"cases" => target.cases,
					"edges" => target.edges,
					"features" => target.features,
					"corpus" => target.corpus,
					"methods" => target.methods,
					"timeline" => target.timeline.map { |seconds, edges| [seconds.round(3), edges] },
					"findings" => target.findings.map do |finding|
						error = finding.failure.errors.first
						failure = finding.failure.failures.first

						{
							"kind" => finding.kind,
							"input" => finding.input,
							"original" => finding.original,
							"cases" => finding.cases,
							"shrinks" => finding.shrinks,
							"error" => error&.then { |it| { "name" => it["name"], "message" => plain(it["message"]), "backtrace" => it["backtrace"].map { |frame| relative_paths(frame) } } },
							"failure" => failure&.then { |it| { "message" => plain(it["message"]), "path" => relative(it["path"]), "line" => it["line"] } },
						}
					end,
				}
			end,
		})
	end

	# What went wrong: the error and where, or the failed assertion's message and line.
	private def details(finding)
		if (error = finding.failure.errors.first)
			message = plain(error["message"]).lines(chomp: true)
			message[0] = "#{error['name']}: #{message[0]}" unless error["name"].start_with?("Quickdraw::Fuzz::")
			message + user_backtrace(error["backtrace"]).first(3).map { |frame| dim(relative_paths(frame)) }
		else
			failure = finding.failure.failures.first
			[*plain(failure["message"]).lines(chomp: true), dim("#{relative(failure['path'])}:#{failure['line']}")]
		end
	end

	private def found(finding)
		shrunk = ", shrunk #{pluralize(finding.shrinks, 'time')}" if finding.shrinks > 0
		"Input (found after #{count(finding.cases)} #{(finding.cases == 1) ? 'case' : 'cases'}#{shrunk})"
	end

	private def summary(target)
		parts = [
			"#{count(target.cases)} cases in #{format('%.1f', target.duration || 0)}s#{format(' (%s/s)', count((target.cases / target.duration).round)) if target.duration&.positive?}",
			pluralize(target.edges, "edge"),
			"#{target.corpus} in the corpus",
			"#{pluralize(target.methods, 'method')} traced",
		]

		parts.join(" · ")
	end

	# When it reached a quarter, a half, three quarters and all of its edges,
	# which shows whether more time would have found more.
	private def edges_over_time(target)
		total = target.timeline.last&.last or return "No edges reached."

		points = [0.25, 0.5, 0.75, 1].filter_map { |fraction| target.timeline.find { |_seconds, edges| edges >= total * fraction } }.uniq
		"Edges: #{points.map { |seconds, edges| "#{edges} by #{format('%.1f', seconds)}s" }.join(', ')}."
	end

	private def rate
		cases = @targets.sum(&:cases)
		"#{count(cases)} cases in #{format('%.1f', @duration)}s#{format(' (%s/s)', count((cases / @duration).round)) if cases > 0} on #{pluralize(@processes, 'worker')}, seed #{@seed}"
	end

	private def progress(target)
		return unless progress?

		found = target.findings.size
		@io.print "\r\e[KFuzzing #{name_of(target.test)} · #{format('%.0f', now - target.started_at)}s of #{format('%g', @seconds)}s · #{count(target.cases)} cases · #{pluralize(target.edges, 'edge')}#{" · #{found} found" if found > 0}"
	end

	private def progress?
		@format == "human" && @io.tty?
	end

	private def error_summary(error)
		[error["name"], plain(error["message"]).lines.first&.chomp].compact.join(": ")
	end

	private def count(number)
		number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
	end

	# Deletes the failing cases saved and the corpora kept for the properties of
	# the test files in `targets`, or of every test without targets, so a
	# property that has changed starts afresh. Those saved before Quickdraw
	# noted their test go only with everything.
	private def forget(targets)
		return usage("--forget takes test files or directories, not lines.") if targets.any? { |target| SPECIFICATION.match(target)[:line] }

		paths = targets.map { |target| (File.expand_path(target) == Dir.pwd) ? "." : relative(File.expand_path(target)) }
		missing = paths.find { |path| !File.exist?(path) }
		return usage("#{missing} doesn’t exist.") if missing

		chosen = lambda do |path|
			test_path = Quickdraw::Property.labelled(path)
			targets.empty? || paths.include?(".") || (test_path && paths.any? { |target| test_path == target || test_path.start_with?("#{target.chomp('/')}/") })
		end

		saved = children(Quickdraw::Property.directory).select { |path| File.file?(path) && chosen.(path) }
		corpora = children(Quickdraw::Fuzz::Corpus.root).select { |path| File.directory?(path) && chosen.(path) }

		require "fileutils"

		begin
			# A file another process deleted first is forgotten all the same.
			[*saved, *corpora].each do |path|
				[path, "#{path}.key"].each { |file| FileUtils.rm_r(file) if File.exist?(file) }
			rescue Errno::ENOENT
				nil
			end
		rescue SystemCallError => error
			warn "Couldn’t forget everything: #{error.message}"
			return 1
		end

		if saved.empty? && corpora.empty?
			@io.puts "Nothing to forget#{" for #{list(paths)}" if targets.any?}."
		else
			@io.puts "Forgot the failing cases saved for #{saved.size} #{(saved.size == 1) ? 'property' : 'properties'} and the corpora of #{pluralize(corpora.size, 'fuzz test')}#{" in #{list(paths)}" if targets.any?}."
		end

		0
	end

	# The files and directories in `directory` that hold cases, not labels or files being written.
	private def children(directory)
		Dir.children(directory).reject { |name| name.include?(".") }.map { |name| File.join(directory, name) }
	rescue SystemCallError
		[]
	end

	# { path => Selection }, or a String if a path doesn't exist.
	private def select(targets)
		return test_files(".").to_h { |path| [path, Selection.new(lines: [], fuzz_tests: true)] } if targets.empty?

		targets.each_with_object({}) do |target, files|
			match = SPECIFICATION.match(target)
			# Relative, as group patterns are.
			path = File.expand_path(match[:path])
			path = (path == Dir.pwd) ? "." : relative(path)
			return "#{path} doesn’t exist." unless File.exist?(path)

			(File.directory?(path) ? test_files(path) : [path]).each do |file|
				selection = files[file] || Selection.new(lines: [], fuzz_tests: false)

				files[file] = if match[:line]
					selection.with(lines: [*selection.lines, Integer(match[:line], 10)])
				else
					selection.with(fuzz_tests: true)
				end
			end
		end
	end

	private def test_files(directory)
		Dir.glob(Quickdraw::CLI::DEFAULT_PATTERN, base: directory)
			.map { |path| File.join(directory, path).delete_prefix("./") }
			.grep_v(Quickdraw::CLI::IGNORED_DIRECTORIES)
			.select { |path| MENTION.match?(File.read(path, encoding: Encoding::UTF_8).scrub) }
	end

	private def parse
		options = { targets: [], processes: nil, seconds: DEFAULT_SECONDS, timeout: DEFAULT_TIMEOUT, seed: nil, format: nil, forget: false }

		until @args.empty?
			argument = @args.shift

			case argument
			in "--"
				options[:targets].concat(@args)
				@args.clear
			in "-p" | "--processes"
				options[:processes] = Integer(@args.shift.to_s, 10, exception: false)
				return usage("#{argument} needs a number of workers, as in #{argument} 4.") unless options[:processes]&.positive?
			in "--seconds"
				options[:seconds] = Float(@args.shift.to_s, exception: false)
				return usage("--seconds needs a number of seconds, as in --seconds 60.") unless options[:seconds]&.positive? && options[:seconds].finite?
			in "--timeout"
				options[:timeout] = Float(@args.shift.to_s, exception: false)
				return usage("--timeout needs a number of seconds, as in --timeout 0.5.") unless options[:timeout]&.positive? && options[:timeout].finite?
			in "-s" | "--seed"
				options[:seed] = Integer(@args.shift.to_s, 10, exception: false)
				return usage("#{argument} needs a number, as in #{argument} 1234.") unless options[:seed]&.between?(0, Quickdraw::CLI::MAX_SEED)
			in "--format"
				options[:format] = @args.shift
				return usage("--format needs one of #{FORMATS.join(', ')}.") unless FORMATS.include?(options[:format])
			in "--forget"
				options[:forget] = true
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
			Usage: #{Quickdraw::Reporters.command} fuzz [PATH[:LINE] …] [options]

			Fuzzes the tests fuzz defines in the files and directories given, or in every test file,
			or the tests given by line, which can be any test that checks a property. Every worker
			fuzzes each test in turn, keeping cases that reach new code in .quickdraw/fuzz/.

			        --seconds N       Fuzz each test for N seconds (default #{DEFAULT_SECONDS})
			        --timeout N       Count a case that runs for N seconds as hanging (default #{DEFAULT_TIMEOUT})
			    -p, --processes N     Run N workers
			    -s, --seed N          Seed the fuzzers with N, for the same cases as another run
			        --format FORMAT   human, agent or json
			        --forget          Fuzz nothing, and delete the failing cases saved and the corpora kept
			                          for the tests in the files and directories given (or every test), as
			                          after changing a property
		TEXT
	end

	private def list(items)
		items.first(3).join(", ") + ((items.size > 3) ? " and #{items.size - 3} more" : "")
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
