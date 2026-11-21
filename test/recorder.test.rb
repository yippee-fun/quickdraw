# frozen_string_literal: true

class RecorderTest < Quickdraw::Test
	BUSY_SECONDS = 0.2
	# Uses CPU for BUSY_SECONDS, however busy the machine is.
	BUSY = [RbConfig.ruby, "--disable-gems", "-e", "nil while Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) < #{BUSY_SECONDS}"].freeze
	CPU = Quickdraw::STATS.index("cpu")

	def recorder = Quickdraw::Worker::Recorder.new
	def stat(recorder, name) = recorder.to_h["stats"][Quickdraw::STATS.index(name)]
	def cpu_seconds(recorder) = stat(recorder, "cpu") / 1_000_000_000.0

	def children_cpu_needed
		skip "Child processes' CPU time is only reported by CRuby" unless RUBY_ENGINE == "ruby"
	end

	test "measure adds each phase's time to its stat, however often it runs" do
		Quickdraw::PHASES.each do |phase|
			recorder = self.recorder

			assert_equal recorder.measure(phase) { sleep 0.002; :returned }, :returned
			once = stat(recorder, phase)
			recorder.measure(phase) { sleep 0.002 }

			assert_operator once, :>=, 2_000_000
			assert_operator stat(recorder, phase), :>=, once + 2_000_000
			assert_equal (Quickdraw::PHASES - [phase]).map { |other| stat(recorder, other) }, [0, 0]
		end
	end

	test "measure records the time of a phase that raises" do
		recorder = self.recorder

		assert_raises(RuntimeError) { recorder.measure("test") { sleep 0.002; raise "failed" } }

		assert_operator stat(recorder, "test"), :>=, 2_000_000
	end

	test "measure_test records the test's duration, allocations and counts" do
		recorder = self.recorder

		recorder.measure_test do
			Quickdraw::Counters.add("queries", 0.5)
			Array.new(100) { Object.new }
			sleep 0.002
		end

		result = recorder.to_h
		assert_operator result["duration"], :>=, 2_000_000
		assert_operator stat(recorder, "allocations"), :>=, Quickdraw::Worker::Recorder::HAS_ALLOCATIONS ? 100 : 0
		assert_equal result["counts"], { "queries" => [1, 0.5] }
	end

	test "a test that counts nothing has no counts" do
		recorder = self.recorder
		recorder.measure_test { nil }

		assert_equal recorder.to_h["counts"], {}
	end

	test "CPU time includes that of a process the test waited for, however it was started" do
		children_cpu_needed

		[
			-> { system(*BUSY) },
			-> { Process.wait(spawn(*BUSY)) },
			-> { IO.popen(BUSY, &:read) },
			-> { `#{BUSY.map { |argument| "'#{argument}'" }.join(" ")}` },
		].each do |start|
			recorder = self.recorder
			recorder.measure_test(&start)

			assert_operator cpu_seconds(recorder), :>=, BUSY_SECONDS
		end
	end

	test "CPU time leaves out processes waited for before the test" do
		children_cpu_needed
		system(*BUSY)

		recorder = self.recorder
		recorder.measure_test { system("true") }

		assert_operator cpu_seconds(recorder), :<, BUSY_SECONDS
	end

	test "CPU time starts from the last test's reading of its children's, when given" do
		children_cpu_needed

		first = recorder
		first.measure_test { system(*BUSY) }
		second = recorder
		second.measure_test(first.children_cpu) { system("true") }

		assert_operator cpu_seconds(first), :>=, BUSY_SECONDS
		assert_operator cpu_seconds(second), :<, BUSY_SECONDS
	end

	test "a plain passing test's result is compact, and expands to the same as to_h" do
		recorder = self.recorder
		recorder.measure_test { recorder.success! }
		result = recorder.to_h

		match { recorder.to_compact => [Integer, Array, 1, {}] }
		assert_equal recorder.to_compact, [result["duration"], result["stats"], 1, {}]
		assert_equal Quickdraw::Worker.result(recorder.to_compact), result
	end

	test "a result with anything to say isn't compact" do
		{
			failure: -> (recorder) { recorder.failure!({ "message" => "failed" }) },
			error: -> (recorder) { recorder.error!({ "name" => "RuntimeError" }) },
			skipped: -> (recorder) { recorder.skip!("later") },
			pending: :pending!.to_proc,
			profile: -> (recorder) { recorder.profile = [["frame", 1]] },
			output: -> (recorder) { recorder.output = "printed" },
			leaks: -> (recorder) { recorder.leaks = [{ "kind" => "env", "message" => "leaked" }] },
			no_assertions: -> (recorder) { recorder.fail_without_assertions("a.test.rb", 1) },
		}.each do |name, change|
			recorder = self.recorder
			recorder.measure_test { recorder.success! unless name == :no_assertions }
			change.call(recorder)

			assert(Hash === recorder.to_compact) { "A result with #{name} was compact." }
			assert_equal recorder.to_compact, recorder.to_h
		end
	end
end
