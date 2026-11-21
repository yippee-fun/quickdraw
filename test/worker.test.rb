# frozen_string_literal: true

require_relative "support/worker_process"

class WorkerTest < Quickdraw::Test
	include WorkerProcess

	BUSY_SECONDS = 0.2
	CPU = Quickdraw::STATS.index("cpu")

	# BUSY uses CPU for BUSY_SECONDS, however busy the machine is. A test that
	# leaves it running waits until it has exited, without waiting for it.
	PROCESSES = <<~RUBY
		BUSY = [RbConfig.ruby, "--disable-gems", "-e", "nil while Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) < #{BUSY_SECONDS}"].freeze

		def leave_busy
			reader, writer = IO.pipe
			spawn(*BUSY, out: writer)
			writer.close
			reader.read
			reader.close
			sleep 0.1
		end
	RUBY

	# Each result the batch sent, by its index, as Recorder#to_h made it.
	def results(messages)
		messages.filter_map { |message| [message[1], Quickdraw::Worker.result(message[2])] if message in [:result, *] }.to_h
	end

	def cpu_seconds(result) = result["stats"][CPU] / 1_000_000_000.0

	def children_cpu_needed
		skip "Child processes' CPU time is only reported by CRuby" unless RUBY_ENGINE == "ruby"
	end

	test "says it started a batch, then sends each test's result in order, a plain pass as just its numbers" do
		worker = start_worker({ "a.test.rb" => <<~RUBY })
			class A < Quickdraw::Test
				test("passes") { assert true; assert true }
				test("fails") { assert false }
				test("skips") { skip "later" }
				test("counts") { Quickdraw::Counters.add("queries"); assert true }
				test("passes again") { assert true }
			end
		RUBY

		assert_equal worker.load("a.test.rb"), ["passes", "fails", "skips", "counts", "passes again"]
		messages = worker.run("a.test.rb", [4, 0, 1, 2, 3])

		failed = skipped = counts = nil

		match do
			messages => [
				[:started],
				[:result, 4, [Integer, Array, 1, {}]],
				[:result, 0, [Integer, Array, 2, {}]],
				[:result, 1, Hash => failed],
				[:result, 2, Hash => skipped],
				[:result, 3, [Integer, Array, 1, Hash => counts]],
			]
		end

		assert_equal failed["failures"].map { |failure| failure["message"] }, ["expected false to be truthy"]
		assert_equal skipped["skipped"], { "pending" => false, "reason" => "later" }
		assert_equal counts, { "queries" => [1, 0.0] }
	end

	test "a test's CPU time leaves out a process its file waited for as it loaded" do
		children_cpu_needed

		source = <<~RUBY
			#{PROCESSES}
			system(*BUSY)

			class Loaded < Quickdraw::Test
				test("quick") { assert system("true") }
				test("busy") { assert system(*BUSY) }
			end
		RUBY

		worker = start_worker({ "a.test.rb" => source, "b.test.rb" => source }, leaks: :warn)
		worker.load("a.test.rb")
		first = results(worker.run("a.test.rb", [0, 1]))
		# After a batch, which is when the next file loads.
		worker.load("b.test.rb")
		second = results(worker.run("b.test.rb", [0, 1]))

		[first, second].each do |batch|
			assert_operator cpu_seconds(batch.fetch(0)), :<, BUSY_SECONDS / 2
			assert_includes BUSY_SECONDS...(BUSY_SECONDS * 1.8), cpu_seconds(batch.fetch(1))
		end
	end

	test "a test's CPU time leaves out a process an earlier test in its batch left, which the leak check waited for" do
		children_cpu_needed

		worker = start_worker({ "a.test.rb" => <<~RUBY }, leaks: :warn)
			#{PROCESSES}

			class Leaves < Quickdraw::Test
				test("leaves a busy process") { leave_busy; assert true }
				test("waits for a quick one") { assert system("true") }
				test("waits for a busy one") { assert system(*BUSY) }
				test("starts none") { assert true }
			end
		RUBY

		worker.load("a.test.rb")
		batch = results(worker.run("a.test.rb", [0, 1, 3, 2]))

		assert_equal batch.fetch(0)["leaks"].map { |leak| leak["kind"] }, ["process"]
		[0, 1, 3].each { |index| assert_operator cpu_seconds(batch.fetch(index)), :<, BUSY_SECONDS / 2 }
		assert_includes BUSY_SECONDS...(BUSY_SECONDS * 1.8), cpu_seconds(batch.fetch(2))
	end

	test "a test's CPU time leaves out an earlier test's process with leak checks off" do
		children_cpu_needed

		worker = start_worker({ "a.test.rb" => <<~RUBY })
			#{PROCESSES}

			class Waits < Quickdraw::Test
				test("waits for a busy process") { assert system(*BUSY) }
				test("waits for a quick one") { assert system("true") }
			end
		RUBY

		worker.load("a.test.rb")
		batch = results(worker.run("a.test.rb", [0, 1]))

		assert_includes BUSY_SECONDS...(BUSY_SECONDS * 1.8), cpu_seconds(batch.fetch(0))
		assert_operator cpu_seconds(batch.fetch(1)), :<, BUSY_SECONDS / 2
	end
end
