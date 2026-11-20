# frozen_string_literal: true

class ConcurrencyTest < Quickdraw::Test
	test "assertions in threads and fibers count towards the test" do
		Thread.new { assert true }.join
		Fiber.new { assert true }.resume
		Enumerator.new { |yielder| yielder << assert(true) }.next
		8.times.map { Thread.new { 100.times { assert true } } }.each(&:join)
	end

	test "joining a thread still raises its exception, and a join that times out still returns nil, with leak checks watching" do
		assert_raises(RuntimeError) { Thread.new { Thread.current.report_on_exception = false; raise "joined" }.join }
		assert_raises(RuntimeError) { Thread.new { Thread.current.report_on_exception = false; raise "valued" }.value }

		sleeping = Thread.new { sleep }
		assert_nil sleeping.join(0.001)
	ensure
		sleeping&.kill&.join
	end

	test "a thread that fails while a property runs fails the test, not one of its cases" do
		started = Thread::Queue.new

		assert_test(passes: 1, failures: 5) do
			failing = Thread.new do
				started.pop
				5.times { assert false }
			end

			check(integer(0..10)) do |n|
				started << true
				sleep 0.001
				assert n <= 10
			end

			failing.join
		end
	end

	test "another test run inside a property's case records its own assertions" do
		inner = nil
		check(integer(0..3)) { |_n| inner = assert_test(passes: 1) { assert true } }
		assert_equal inner.successes, 1
	end

	test "a case's thread that asserts after the case goes to the test" do
		recorder = Quickdraw::Property::Recorder.new
		after = Quickdraw::Property::Recorder.new
		recorder.failure!({ "message" => "during" })
		recorder.close(after)
		recorder.failure!({ "message" => "after" })

		assert_equal recorder.failure.failures.map { |failure| failure["message"] }, ["during"]
		assert_equal after.failure.failures.map { |failure| failure["message"] }, ["after"]
	end

	test "counters a test's threads add count towards it, even after it ends" do
		Quickdraw::Counters.start
		Thread.new { Quickdraw::Counters.add("sql", 0.5) }.join
		late = Thread.new { sleep 0.02; Quickdraw::Counters.add("sql") }
		assert_equal Quickdraw::Counters.take, { "sql" => [1, 0.5] }

		Quickdraw::Counters.start
		late.join
		assert_equal Quickdraw::Counters.take, {}
	end

	test "Quickdraw's constants are shareable with Ractors, except config and methods" do
		skip "This Ruby has no Ractors." unless defined?(Ractor)

		# Loaded, as they may not be yet.
		[
			Quickdraw::Commands::Fuzz,
			Quickdraw::Commands::Mutate,
			Quickdraw::Sampler,
			Quickdraw::CoverageCollector,
			Quickdraw::Generators,
			Quickdraw::Fuzz::Session,
			Quickdraw::Fuzz::Edges,
			Quickdraw::Worker,
			Quickdraw::Reporters::Formatting,
			Quickdraw::Inspector,
			Quickdraw::History,
			Quickdraw::Mutation::Mutator,
			Quickdraw::Mutation::Planner,
			Quickdraw::Mutation::Plan,
			Quickdraw::Mutation::Marks,
			Quickdraw::Mutation::Report,
			Quickdraw::Mutation::Survivors,
			Quickdraw::Browser::Bridge,
		]

		unshareable = []
		seen = {}

		walk = lambda do |mod|
			next if seen[mod]

			seen[mod] = true

			mod.constants(false).each do |name|
				next if mod.autoload?(name)

				case mod.const_get(name, false)
				in Module => child then walk.(child) if child.name&.start_with?("Quickdraw::")
				in value then unshareable << "#{mod}::#{name}" unless Ractor.shareable?(value)
				end
			end
		end

		walk.(Quickdraw)

		assert_equal unshareable.sort, [
			"Quickdraw::Config",
			"Quickdraw::Fuzz::Edges::INSTANCE_METHOD",
			"Quickdraw::Fuzz::Edges::INSTANCE_METHODS",
			"Quickdraw::Fuzz::Edges::PRIVATE_INSTANCE_METHODS",
			"Quickdraw::Inspector::DATA_TO_H",
			"Quickdraw::Inspector::PUBLIC_SEND",
			"Quickdraw::Inspector::STRUCT_EACH_PAIR",
		]
	end
end
