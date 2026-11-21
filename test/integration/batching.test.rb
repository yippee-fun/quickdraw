# frozen_string_literal: true

require_relative "../support/integration"

# A worker sends the results of passing tests together (see
# Quickdraw::Worker::RESULTS_AT_ONCE), which the coordinator must not be able
# to tell from one at a time.
class BatchingTest < Quickdraw::Test
	include Integration

	PASSING = 80

	def setup
		super
		skip "Replacing crashed workers and timing tests out need fork" unless Process.respond_to?(:fork)
	end

	def among_passing(test)
		<<~RUBY
			class Batched < Quickdraw::Test
				#{PASSING}.times { |number| test("passes \#{number}") { assert true } }
				#{test}
			end
		RUBY
	end

	test "reports every test once, each with its own result, whatever was sent together", timeout: 30 do
		require "json"

		project = project("batched.test.rb" => among_passing(<<~RUBY))
			test("fails") { assert_equal 1, 2 }
			test("skips") { skip "later" }
			test("counts") { Quickdraw::Counters.add("queries"); 3.times { assert true } }
		RUBY

		[["-p", "1"], ["-p", "3"]].each do |workers|
			result = project.run(*workers, "--no-history", "--format", "json")
			tests = result.stdout.lines.map { |line| JSON.parse(line) }.select { |event| event["event"] == "test" }

			assert_equal tests.map { |test| test["name"] }.sort, [*Array.new(PASSING) { |number| "Batched › passes #{number}" }, "Batched › fails", "Batched › skips", "Batched › counts"].sort
			assert_equal tests.map { |test| test["status"] }.tally, { "passed" => PASSING + 1, "failed" => 1, "skipped" => 1 }
			assert(tests.all? { |test| test["status"] == "skipped" || test["duration"] > 0 })
			match { JSON.parse(result.stdout.lines.last, symbolize_names: true) => { event: "finish", tests: ^(PASSING + 3), assertions: ^(PASSING + 4), failed: 1, skipped: 1 } }
		end
	end

	test "records each test's own timings in the run history", timeout: 30 do
		skip "Run history needs sqlite3" unless bundled?("sqlite3")

		require "sqlite3"
		project = project("batched.test.rb" => among_passing('test("slow") { sleep 0.05; 5.times { assert true } }'))
		project.run("-p", "1")
		database = SQLite3::Database.new(File.join(project.directory, ".quickdraw/history.sqlite3"))
		defer { database.close }
		rows = database.execute("SELECT tests.description, results.status, results.duration, results.body, results.assertions FROM results JOIN tests ON tests.id = results.test_id")
		slow, *quick = rows.sort_by { |description, *| (description == "slow") ? 0 : 1 }

		assert_equal rows.size, PASSING + 1
		match { slow => ["slow", "passed", 0.05..5, 0.05..5, 5] }
		assert(quick.all? { |_description, status, duration, body, assertions| status == "passed" && duration.between?(0, 0.05) && body <= duration && assertions == 1 })
	end

	test "finds the test that killed its worker among those whose results it hadn't sent", timeout: 60 do
		project = project("batched.test.rb" => among_passing('test("kills its worker") { exit!(3) }'))

		[["-p", "1", "--seed", "1"], ["-p", "1", "--seed", "2"], ["-p", "3", "--seed", "3"]].each do |arguments|
			result = project.run(*arguments, "--no-history", "--format", "agent")

			refute result.success?
			assert_equal result.stdout.scan(/^ERROR \S+ (.*?):/).uniq.size, 1
			assert_match result.stdout, /^ERROR batched\.test\.rb:\d+ Batched › kills its worker: Quickdraw::WorkerCrashed/
			assert_includes result.stdout, "FAILED: #{PASSING + 1} tests, #{PASSING} passed, 1 errored"
		end
	end

	test "fails the run when a worker is killed by a test that doesn't do it again alone", timeout: 60 do
		[["agent", 1], ["agent", 2], ["human", 3]].each do |format, seed|
			project = project("batched.test.rb" => among_passing(<<~'RUBY'))
				test("kills its worker once") do
					killed = "#{__dir__}/killed"

					unless File.exist?(killed)
						File.write(killed, "")
						puts "its last words"
						exit!(0)
					end

					assert true
				end
			RUBY

			result = project.run("-p", "1", "--no-history", "--seed", seed.to_s, "--format", format)

			refute result.success?
			assert File.exist?(File.join(project.directory, "killed"))

			# The test is only known if it ran in a batch of its own.
			if result.stdout.include?("Quickdraw::WorkerCrashed")
				assert_includes result.stdout, "1 errored"
			else
				assert_includes result.stdout, "A worker exited while it ran tests, and none of them made a worker exit again when run alone."
				refute_includes result.stdout, "errored"
			end

			# What the worker printed isn't lost with it.
			assert_equal result.stdout.scan("its last words").size, 1 if format == "human"
		end
	end

	test "times out the test that hangs, not one whose result was waiting to be sent", timeout: 60 do
		project = project(
			"config/quickdraw.rb" => "Quickdraw.configure { |config| config.timeout = 0.5 }\n",
			"batched.test.rb" => among_passing('test("hangs") { sleep }'),
		)

		[["-p", "1", "--seed", "1"], ["-p", "3", "--seed", "2"]].each do |arguments|
			result = project.run(*arguments, "--no-history", "--format", "agent")

			refute result.success?
			assert_equal result.stdout.scan(/^ERROR \S+ (.*?):/).uniq.size, 1
			assert_match result.stdout, /^ERROR batched\.test\.rb:\d+ Batched › hangs: Quickdraw::Timeout: The test took longer than its 0\.5s timeout\./
			assert_includes result.stdout, "FAILED: #{PASSING + 1} tests, #{PASSING} passed, 1 errored"
		end
	end
end
