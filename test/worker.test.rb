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

	# Each result in the messages, in the order sent, as [index, result], with
	# the result as Recorder#to_h made it.
	def each_result(messages)
		pairs = []

		messages.each do |message|
			Quickdraw::Worker.each_result(message) { |index, result| pairs << [index, result] } if message in [:result | :integers, *]
		end

		pairs
	end

	def results(messages) = each_result(messages).to_h

	# The indices of the tests whose results each message has.
	def indices(messages) = messages.map { |message| each_result([message]).map(&:first) }

	def cpu_seconds(result) = result["stats"][CPU] / 1_000_000_000.0

	def children_cpu_needed
		skip "Child processes' CPU time is only reported by CRuby" unless RUBY_ENGINE == "ruby"
	end

	MIXED = <<~RUBY
		class Mixed < Quickdraw::Test
			test("passes") { assert true; assert true }
			test("fails") { assert_equal 1, 2 }
			test("skips") { skip "later" }
			test("counts") { Quickdraw::Counters.add("queries"); assert true }
			test("passes again") { assert true }
			test("raises") { raise "broken" }
			test("passes last") { assert true }
			test("has its own timeout", timeout: 5) { assert true }
			test("is pending")
			test("passes at the end") { assert true }
		end
	RUBY

	test "sends the results of plain passing tests together, once the batch has finished" do
		worker = start_worker({ "a.test.rb" => <<~RUBY })
			class Plain < Quickdraw::Test
				5.times { |number| test("passes \#{number}") { (number + 1).times { assert true } } }
			end
		RUBY

		worker.load("a.test.rb")
		messages = worker.run("a.test.rb", [3, 0, 4, 1, 2])

		match { messages => [[:started], [:integers, Array]] }
		assert_equal messages.last.last.size, 5 * Quickdraw::Worker::RESULT_INTEGERS
		assert_equal(each_result(messages).map { |index, result| [index, result["assertions"]] }, [[3, 4], [0, 1], [4, 5], [1, 2], [2, 3]])
	end

	test "a result sent with others is the same as one sent alone" do
		worker = start_worker({ "a.test.rb" => "class Plain < Quickdraw::Test; test('passes') { assert true }; end\n" })
		worker.load("a.test.rb")
		result = results(worker.run("a.test.rb", [0])).fetch(0)

		assert_equal result.keys, Quickdraw::Worker::Recorder.new.to_h.keys
		assert_equal result.except("duration", "stats"), { "assertions" => 1, "failures" => [], "errors" => [], "skipped" => nil, "profile" => nil, "counts" => {} }
		assert_operator result["duration"], :>, 0
		assert_equal result["stats"].size, Quickdraw::STATS.size
		assert_operator result["stats"][Quickdraw::STATS.index("test")], :<=, result["duration"]
		assert_operator result["stats"][Quickdraw::STATS.index("allocations")], :>, 0 if Quickdraw::Worker::Recorder::HAS_ALLOCATIONS
	end

	test "sends at most RESULTS_AT_ONCE results together" do
		count = (Quickdraw::Worker::RESULTS_AT_ONCE * 2) + 10

		worker = start_worker({ "a.test.rb" => <<~RUBY })
			class Many < Quickdraw::Test
				#{count}.times { |number| test("passes \#{number}") { assert true } }
			end
		RUBY

		worker.load("a.test.rb")
		messages = worker.run("a.test.rb", (0...count).to_a)

		assert_equal indices(messages).map(&:size), [0, Quickdraw::Worker::RESULTS_AT_ONCE, Quickdraw::Worker::RESULTS_AT_ONCE, 10]
		assert_equal indices(messages).flatten, (0...count).to_a
	end

	test "sends anything but a plain pass alone and whole, after the results that were waiting, so every result arrives in order" do
		worker = start_worker({ "a.test.rb" => MIXED })

		assert_equal worker.load("a.test.rb").size, 10
		messages = worker.run("a.test.rb", [0, 4, 1, 6, 2, 3, 5, 7, 8, 9])

		assert_equal messages.map(&:first), [:started, :integers, :result, :integers, :result, :result, :result, :result, :result, :integers]
		assert_equal indices(messages), [[], [0, 4], [1], [6], [2], [3], [5], [7], [8], [9]]

		results = results(messages)
		failure = results.fetch(1)["failures"].fetch(0)
		assert_equal [failure["line"], File.basename(failure["path"])], [3, "a.test.rb"]
		assert_includes failure["message"], "1"
		assert_equal results.fetch(2)["skipped"], { "pending" => false, "reason" => "later" }
		assert_equal results.fetch(3)["counts"], { "queries" => [1, 0.0] }
		assert_equal results.fetch(5)["errors"].map { |error| [error["name"], error["message"]] }, [["RuntimeError", "broken"]]
		assert_equal results.fetch(7)["assertions"], 1
		assert_equal results.fetch(8)["skipped"], { "pending" => true, "reason" => nil }
	end

	test "sends a slow test's result as it finishes, with those waiting", timeout: 20 do
		worker = start_worker({ "a.test.rb" => <<~RUBY }, unsent_time: Quickdraw::Worker::UNSENT_TIME)
			class Slow < Quickdraw::Test
				test("quick") { assert true }
				test("slow") { sleep #{Quickdraw::Worker::UNSENT_TIME / 1e9}; assert true }
				test("waits to be told its results arrived") { sleep 0.005 until File.exist?("\#{__dir__}/arrived"); assert true }
			end
		RUBY

		worker.load("a.test.rb")
		worker.start("a.test.rb", [0, 1, 2])

		assert_equal worker.read, [:started]
		# Together, unless the machine is slow enough for the quick one to be sent first.
		arrived = []
		arrived.concat(indices([worker.read]).flatten) until arrived.size >= 2
		assert_equal arrived, [0, 1]
		File.write(worker.path("arrived"), "")
		assert_equal indices([worker.read]), [[2]]
		assert_equal worker.read.first, :ready
	end

	test "sends the results that are waiting before it runs a test with its own timeout", timeout: 20 do
		worker = start_worker({ "a.test.rb" => <<~RUBY })
			class Timed < Quickdraw::Test
				2.times { |number| test("quick \#{number}") { assert true } }
				test("waits to be told its results arrived", timeout: 30) { sleep 0.005 until File.exist?("\#{__dir__}/arrived"); assert true }
			end
		RUBY

		worker.load("a.test.rb")
		worker.start("a.test.rb", [0, 1, 2])

		assert_equal worker.read, [:started]
		assert_equal indices([worker.read]), [[0, 1]]
		File.write(worker.path("arrived"), "")
		assert_equal worker.read.first(2), [:result, 2]
		assert_equal worker.read.first, :ready
	end

	test "sends the results that are waiting before it says a test timed out, then exits", timeout: 20 do
		worker = start_worker({ "a.test.rb" => <<~RUBY }, timeouts: true, timeout: 0.2)
			class Hangs < Quickdraw::Test
				3.times { |number| test("quick \#{number}") { assert true } }
				test("hangs") { sleep }
				test("is never run") { assert true }
			end
		RUBY

		worker.load("a.test.rb")
		messages = worker.run("a.test.rb", [0, 1, 2, 3, 4])

		assert_equal messages.map { |message| message&.first }, [:started, :integers, :timeout, nil]
		assert_equal indices(messages.first(2)), [[], [0, 1, 2]]
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

	test "a test's CPU time leaves out a process an earlier test leaked, which a later leak check waited for" do
		children_cpu_needed

		worker = start_worker({ "a.test.rb" => <<~RUBY }, leaks: :warn)
			#{PROCESSES}

			class Leaks < Quickdraw::Test
				test("leaves a busy process running") { spawn(*BUSY); assert true }
				test("starts none while it runs") { assert true }
				test("waits until it has exited") { sleep(#{BUSY_SECONDS * 2.5}); assert true }
				test("starts none after") { assert true }
			end
		RUBY

		worker.load("a.test.rb")
		batch = results(worker.run("a.test.rb", [0, 1, 2, 3]))

		assert_equal batch.fetch(0)["leaks"].map { |leak| leak["kind"] }, ["process"]
		[0, 1, 2, 3].each { |index| assert_operator cpu_seconds(batch.fetch(index)), :<, BUSY_SECONDS / 2 }
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
