# frozen_string_literal: true

class FuzzTest < Quickdraw::Test
	Entry = Quickdraw::Fuzz::Mutator::Entry
	ENTRY = Entry.new(choices: [1, 5, 1, 3, 0], limits: [1, 9, 1, 9, 1], spans: [0...2, 2...4])
	OTHER = Entry.new(choices: [1, 7, 0], limits: [1, 9, 1], spans: [0...2])

	EXAMPLE = <<~RUBY
		module Example
			def self.classify(n)
				if n > 10
					:big
				else
					:small
				end
			end

			def self.repeat(n)
				n.times { nil }
			end

			attr_reader :untraceable
		end
	RUBY

	# A project with Example in lib/ and a helper in test/, loaded into a scope
	# of their own.
	def load_example
		root = tmpdir
		scope = Module.new
		Dir.mkdir(File.join(root, "lib"))
		Dir.mkdir(File.join(root, "test"))

		{ "lib/example.rb" => EXAMPLE, "test/helper.rb" => "module Helper\n  def self.help = nil\nend\n" }.each do |path, source|
			File.write(File.join(root, path), source)
			Kernel.load(File.join(root, path), scope)
		end

		[root, scope::Example]
	end

	describe "Edges" do
		test "tells cases that take different paths through the project's own methods apart" do
			skip "Edge tracing needs CRuby's TracePoint, and fuzz needs fork anyway" unless RUBY_ENGINE == "ruby"

			root, example = load_example
			edges = Quickdraw::Fuzz::Edges.new(root)
			# Not the test helper's, nor attr_reader's, which has no code.
			assert_equal edges.trace, 2

			example.classify(20)
			big = edges.take
			example.classify(1)
			small = edges.take
			example.classify(30)

			assert_equal edges.take.sort, big.sort
			refute_equal big.sort, small.sort
			assert_equal edges.take, []
		end

		test "counts how often an edge runs, in buckets" do
			skip "Edge tracing needs CRuby's TracePoint, and fuzz needs fork anyway" unless RUBY_ENGINE == "ruby"

			root, example = load_example
			edges = Quickdraw::Fuzz::Edges.new(root)
			edges.trace

			example.repeat(4)
			four = edges.take
			example.repeat(7)
			seven = edges.take
			example.repeat(8)

			assert_equal seven.sort, four.sort
			refute_equal edges.take.sort, four.sort
		end
	end

	describe "Mutator" do
		test "changes an entry's choices, keeping them choices" do
			mutator = Quickdraw::Fuzz::Mutator.new(Random.new(1))
			mutants = Array.new(1000) { mutator.call(ENTRY, OTHER) }

			assert mutants.all? { |choices| choices.all? { |choice| Integer === choice && choice >= 0 } }
			assert_operator mutants.uniq.size, :>, 100
			# The first item deleted, the second duplicated, and the other entry's item spliced in.
			assert_includes mutants, [1, 3, 0]
			assert_includes mutants, [1, 5, 1, 3, 1, 3, 0]
			assert mutants.any? { |choices| choices.each_cons(2).include?([1, 7]) }
		end

		test "makes the same changes from the same seed" do
			first = Quickdraw::Fuzz::Mutator.new(Random.new(2))
			second = Quickdraw::Fuzz::Mutator.new(Random.new(2))

			assert_equal Array.new(50) { first.call(ENTRY, OTHER) }, Array.new(50) { second.call(ENTRY, OTHER) }
		end

		test "leaves no choices alone" do
			assert_equal Quickdraw::Fuzz::Mutator.new(Random.new(1)).call(Entry.new(choices: [], limits: [], spans: []), OTHER), []
		end
	end

	test "keeps the simplest finding of each failure across workers" do
		target = Quickdraw::Commands::Fuzz::Target.new("test/example.test.rb", {}, 0)
		failure = Quickdraw::Property::Failure.new(failures: [], errors: [{ "name" => "RuntimeError", "backtrace" => ["lib/example.rb:1"] }])
		finding = -> (choices) { Quickdraw::Fuzz::Finding.new(kind: "errored", key: "key", choices:, input: choices.inspect, original: nil, failure:, cases: 1, shrinks: 0) }

		target.found(finding.([1, 2]))
		target.found(finding.([3, 0]))
		target.found(finding.([1, 2, 0]))
		assert_equal target.findings.map(&:choices), [[1, 2]]

		target.found(finding.([1, 1]))
		assert_equal target.findings.map(&:choices), [[1, 1]]

		target.found(finding.([9]))
		assert_equal target.findings.map(&:choices), [[9]]

		# Over one found while generating, which has none.
		target.found(finding.(nil))
		assert_equal target.findings.map(&:choices), [[9]]
	end

	test "a fuzzer the session restarts after a crash doesn't report failures again" do
		skip "fuzz needs fork" unless Process.respond_to?(:fork)

		root = tmpdir
		stub(Quickdraw::Fuzz::Corpus, :root) { File.join(root, "fuzz") }
		directory = Quickdraw::Property.directory
		Quickdraw::Property.directory = File.join(root, "properties")
		defer { Quickdraw::Property.directory = directory }

		test_class = Class.new(Quickdraw::Test)
		definition = Quickdraw.collect_tests("restarts", {}) do
			test_class.fuzz("crashes and fails", integer(0..100)) do |n|
				Process.kill(:KILL, Process.pid) if n.between?(1, 3)
				assert n < 50
			end
		end.first

		messages = []
		channel = Object.new
		channel.define_singleton_method(:write) { |message| messages << message }
		Quickdraw::Fuzz::Session.new(channel, definition, seconds: 1, timeout: 1, seed: 1, test_seed: 1, explicit: true).call

		kinds = messages.filter_map { |message| message in [:fuzz_finding, finding] and finding.kind }
		assert_equal kinds.tally, { "crashed" => 1, "failed" => 2 }
	end

	test "fuzz defines a test that checks its block with the generators" do
		test_class = Class.new(Quickdraw::Test)
		inputs = []

		definition = Quickdraw.collect_tests("fuzz example", {}) do
			test_class.fuzz("doubles", integer(0..9), cases: 20) { |n| inputs << n }
		end.first

		runner = Runner.new
		test_class.new(description: definition.description, block: definition.block, runner:).run

		assert_equal definition.description, "doubles"
		assert_equal definition.line, __LINE__ - 7
		assert_equal inputs.size, 20
		assert inputs.all? { |n| (0..9).cover?(n) }
		assert_equal runner.successes, 1
		assert_raises(ArgumentError) { test_class.fuzz("no generator") { |input| input } }
		assert_raises(ArgumentError) { test_class.fuzz("hangs", integer, hang_after: 0) { |n| n } }
	end

	test "fuzz without generators defines a test whose block calls check, with setup before its cases and checks after" do
		test_class = Class.new(Quickdraw::Test)
		events = []

		definition = Quickdraw.collect_tests("fuzz body", {}) do
			test_class.fuzz("around its cases", hang_after: 30) do
				events << :before
				check(integer(0..9), cases: 5) { |n| events << n }
				events << :after
				assert true
			end
		end.first

		runner = Runner.new
		test_class.new(description: definition.description, block: definition.block, runner:).run

		assert_equal events.first, :before
		assert_equal events.last, :after
		assert_equal events.size, 7
		assert_equal test_class.fuzz_target(definition.block).hang_after, 30
		assert_equal runner.failures, []
	end

	test "a case runs for a fuzz test's hang_after, not --timeout, before it hangs" do
		skip "fuzz needs fork" unless Process.respond_to?(:fork)

		root = tmpdir
		stub(Quickdraw::Fuzz::Corpus, :root) { File.join(root, "fuzz") }
		directory = Quickdraw::Property.directory
		Quickdraw::Property.directory = File.join(root, "properties")
		defer { Quickdraw::Property.directory = directory }

		test_class = Class.new(Quickdraw::Test)
		definition = Quickdraw.collect_tests("slow", {}) do
			test_class.fuzz("starts slowly", integer(0..3), hang_after: 2) do |n|
				sleep 0.3 if n == 3
				assert true
			end
		end.first

		messages = []
		channel = Object.new
		channel.define_singleton_method(:write) { |message| messages << message }
		Quickdraw::Fuzz::Session.new(channel, definition, seconds: 1, timeout: 0.1, seed: 1, test_seed: 1, explicit: false).call

		assert_equal messages.filter_map { |message| message in [:fuzz_finding, finding] and finding.kind }, []
		assert_equal messages.last, [:fuzzed, ["fuzzed"]]
	end
end
