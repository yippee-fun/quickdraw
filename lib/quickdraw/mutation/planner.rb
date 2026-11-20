# frozen_string_literal: true

# Finds what `quickdraw mutate` runs (a Plan): the mutants of the targets, or
# of the lines changed since `base`, and the test files that run them. Loads
# Prism, sqlite3 and digest, so it only runs in a throwaway process (see
# Quickdraw.isolate), where they can't reach workers.
class Quickdraw::Mutation::Planner
	include Quickdraw::Reporters::Formatting

	# The targets can't be found.
	class Error < StandardError; end

	SPECIFICATION = /\A(?<path>.+?)(?::(?<first>\d+)(?:-(?<last>\d+))?)?\z/

	# `targets` are paths, each with an optional line or range of lines. With
	# `unique_kills`, also finds the tests this adds or changes, and every other
	# mutant (reach) of the source files they run, so they can be judged
	# against all the code they run.
	def initialize(targets, base:, unique_kills:)
		@targets = targets
		@base = base
		@unique_kills = unique_kills
	end

	def call
		mutants = []
		ignored = []
		warnings = []

		sources.each do |path, lines|
			kept, equivalent, problems = mutants_of(path, lines)
			mutants.concat(kept)
			ignored.concat(equivalent)
			warnings.concat(problems)
		end

		changed_tests = @unique_kills ? changed_test_lines : {}
		reach = @unique_kills ? others_run_by(changed_tests.keys, mutants) : []

		source_files = [*mutants, *reach].map { |mutant| relative(mutant.subject.path) }.uniq
		test_files, mapped = covering_test_files(source_files)
		test_files = (test_files + changed_tests.keys).uniq

		# Ids for the ignored too, so marking one doesn't change its neighbours'.
		numbered = [*mutants, *ignored.map(&:first), *reach].each_with_index.map { |mutant, index| mutant.with(id: index) }

		Quickdraw::Mutation::Plan.new(
			mutants: numbered.first(mutants.size),
			ignored: numbered[mutants.size, ignored.size].zip(ignored.map(&:last)),
			reach: numbered.last(reach.size),
			keys: keys(numbered),
			changed_tests:,
			test_files:,
			mapped:,
			warnings:,
			processes: Quickdraw::Platform.non_blocking_cores,
			fingerprints: fingerprints(test_files, source_files),
			cache: Quickdraw::Mutation::Cache.read,
		)
	end

	# { path => lines, or nil for all of them }
	private def sources
		@targets.empty? ? changed_sources : given_sources
	end

	# { path => changed lines } for the project's own Ruby files.
	private def changed_sources
		changes = Quickdraw::Changes.lines(base: @base) or raise Error, "mutate needs a git repository to see what’s changed, or files to mutate."
		changes.select { |path, _lines| source?(path) && File.file?(path) }
	rescue Quickdraw::Changes::UnknownBase => error
		raise Error, error.message
	end

	private def given_sources
		@targets.each_with_object({}) do |target, sources|
			match = SPECIFICATION.match(target) or raise Error, "#{target} doesn’t exist."
			path = match[:path].delete_prefix("#{Dir.pwd}/").delete_prefix("./")
			path = "." if path.empty?

			if File.directory?(path)
				files = Dir.glob("**/*.rb", base: path).map { |file| File.join(path, file).delete_prefix("./") }
				files.select { |file| source?(file) }.each { |file| sources[file] = nil }
			elsif File.file?(path)
				lines = (Integer(match[:first], 10)..Integer(match[:last] || match[:first], 10)).to_a if match[:first]
				sources[path] = lines && (sources.key?(path) ? sources[path]&.union(lines) : lines)
			else
				raise Error, "#{path} doesn’t exist."
			end
		end
	end

	private def source?(path)
		path.end_with?(".rb") && !Quickdraw::CoverageCollector::EXCLUDED.match?(path) && path != Quickdraw::Loader::CONFIG_PATH
	end

	# The mutants of `path` that change `lines` (or any line, if nil), then
	# those marked equivalent, as [mutant, reason], then warnings.
	private def mutants_of(path, lines)
		source = File.read(path, encoding: Encoding::UTF_8)
		mutants = Quickdraw::Mutation::Mutator.new(File.expand_path(path), source, relative_path: path).call(lines:)
		marks = Quickdraw::Mutation::Marks.new(path, source)
		[*marks.partition(mutants), marks.warnings(mutants, lines)]
	rescue SyntaxError => error
		[[], [], ["Couldn’t parse #{path}: #{error.message}"]]
	end

	# { test path => lines its tests that this adds or changes start at }
	private def changed_test_lines
		changed = Quickdraw::Changes.lines(base: @base, deletions: true) || {}

		changed.each_with_object({}) do |(path, lines), changed_tests|
			next unless path.end_with?(Quickdraw::Commands::Counterpart::TEST_SUFFIX) && File.file?(path)

			starts = test_starts(path, lines)
			changed_tests[path] = starts if starts.any?
		end
	rescue Quickdraw::Changes::UnknownBase => error
		raise Error, error.message
	end

	# Where each `test` call with a changed line starts its block, which is
	# the line a test is defined at.
	private def test_starts(path, lines)
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

	# The mutants of the source files `test_paths` run, but not `mutants`.
	private def others_run_by(test_paths, mutants)
		mutated = mutants.to_h { |mutant| [identity(mutant), true] }

		sources_run_by(test_paths).flat_map do |path|
			kept, _equivalent, _warnings = mutants_of(path, nil)
			kept.reject { |mutant| mutated.key?(identity(mutant)) }
		end
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

	# Ids that stay the same across runs while the method's code does, since
	# they don't include where the method is: the file, method, change, the
	# code it makes, its line within the method, and which of the identical
	# changes on that line it is. 48 bits, so ids rarely collide even across
	# hundreds of thousands of mutants.
	private def keys(mutants)
		seen = Hash.new(0)

		mutants.to_h do |mutant|
			# Without marks, so marking one doesn't change its neighbours' ids.
			identity = [relative(mutant.subject.path), mutant.subject.label, mutant.description, mutant.after.gsub(Quickdraw::Mutation::Marks::COMMENT, "").strip, mutant.line - mutant.subject.line]
			seen[identity] += 1
			[mutant.id, Quickdraw.stable_hash([*identity, seen[identity]].join("\0")).to_s(16).rjust(16, "0")[0, 12]]
		end
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

		# Helpers in test directories, such as test/support/, which coverage
		# doesn't map. Not lib/ for colocated tests, or every source would count.
		helpers = Dir.glob("{#{Quickdraw::Commands::Counterpart::TEST_DIRECTORIES.join(',')}}/**/*.rb").reject { |path| path.end_with?(Quickdraw::Commands::Counterpart::TEST_SUFFIX) }

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
end
