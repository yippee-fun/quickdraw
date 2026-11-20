# frozen_string_literal: true

class PropertyTest < Quickdraw::Test
	def setup
		directory = Quickdraw::Property.directory
		Quickdraw::Property.directory = File.join(tmpdir, "properties")
		defer { Quickdraw::Property.directory = directory }
	end

	def message(runner)
		Quickdraw.utf8(runner.failures.first["message"])
	end

	test "a property that holds is one assertion" do
		cases = 0

		assert_test(passes: 1) do
			check(integer) do |n|
				cases += 1
				assert Integer === n
			end
		end

		assert_equal cases, 100
	end

	test "runs the cases given, or until the time runs out" do
		cases = 0
		assert_test(passes: 1) { check(boolean, cases: 7) { cases += 1 } }
		assert_equal cases, 7

		started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
		assert_test(passes: 1) { check(boolean, cases: Float::INFINITY, seconds: 0.05) { nil } }
		assert_in_delta Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at, 0.05, 0.05
	end

	test "reports the shrunk counterexample, the original and the case it was found in" do
		runner = assert_test(failures: 1) do
			check(array(integer)) { |list| assert list.size < 3 }
		end

		assert_includes message(runner), "Counterexample (found after"
		assert_includes message(runner), "\n\n[0, 0, 0]\n\n"
		assert_includes message(runner), "Shrunk from:"
		assert_includes message(runner), "expected false to be truthy"
		assert_equal runner.failures.first["line"], __LINE__ - 7
	end

	test "shows each value of a property with several generators" do
		runner = assert_test(failures: 1) do
			check(integer(0..), boolean) { |n, flag| assert n < 5 || !flag }
		end

		assert_includes message(runner), "\n\n5, true\n\n"
	end

	test "shrinks through map and flat_map" do
		runner = assert_test(failures: 1) do
			check(integer(0..).map { |n| n * 2 }) { |n| assert n < 100 }
		end

		assert_includes message(runner), "\n\n100\n\n"

		runner = assert_test(failures: 1) do
			check(integer(1..5).flat_map { |n| array(integer(0..), length: n) }) { |list| assert list.sum < 10 }
		end

		assert_includes message(runner), "\n\n[10]\n\n"
	end

	test "reports an error with the counterexample" do
		runner = assert_test(errors: 1) do
			check(integer(0..)) { |n| raise "boom" if n > 10 }
		end

		error = runner.errors.first
		assert_equal error["name"], "RuntimeError"
		assert_match error["message"], /\Aboom\n\n.*Counterexample.*\n\n11\n\n/m
	end

	test "shrinks by deleting adjacent values together, when deleting either alone passes" do
		runner = assert_test(failures: 1) do
			check(array(integer(1..3))) { |list| refute list.include?(3) && list.sum.odd? }
		end

		assert_includes message(runner), "\n\n[3]\n\n"
	end

	test "shrinks to a case that fails the same way" do
		runner = assert_test(errors: 1) do
			check(integer(0..)) do |n|
				raise ArgumentError if n > 100
				raise TypeError if n > 10
			end
		end

		error = runner.errors.first
		simplest = { "ArgumentError" => 101, "TypeError" => 11 }.fetch(error["name"])
		assert_includes error["message"], "\n\n#{simplest}\n\n"
	end

	test "the test carries on after a property fails" do
		assert_test(passes: 1, failures: 1) do
			check(boolean) { |value| assert value }
			assert true
		end
	end

	test "skip in a property skips the test" do
		runner = assert_test { check(integer) { skip "not today" } }

		assert_equal runner.skipped, { "pending" => false, "reason" => "not today" }
	end

	test "the run's seed chooses the cases" do
		draws = -> do
			values = []
			assert_test(passes: 1) { check(integer, cases: 20) { |n| values << n } }
			values
		end

		Kernel.srand(42)
		first = draws.call
		Kernel.srand(42)
		assert_equal draws.call, first
		Kernel.srand(43)
		refute_equal draws.call, first
	end

	test "a failing case is saved, replayed first, and deleted once it passes" do
		fixed = false
		values = []

		property = proc do
			check(integer(0..)) do |n|
				values << n
				assert fixed || n < 50
			end
		end

		assert_test(failures: 1, &property)
		# With a label naming the test, for `quickdraw fuzz --forget`.
		saved = Dir.children(Quickdraw::Property.directory)
		assert_equal saved.size, 2
		assert_includes File.read(File.join(Quickdraw::Property.directory, saved.find { |name| name.end_with?(".key") })), "test/property.test.rb\0"

		values.clear
		runner = assert_test(failures: 1, &property)
		assert_equal values.first, 50
		assert_includes message(runner), "Counterexample (saved from an earlier run):\e[0m\n\n50\n\n"
		refute_includes message(runner), "Shrunk from"

		fixed = true
		values.clear
		assert_test(passes: 1, &property)
		assert_equal values.first, 50
		assert_equal values.size, 101
		assert_equal Dir.children(Quickdraw::Property.directory), []
	end

	test "replays each of several saved cases, as fuzzing saves them, forgetting those that pass" do
		Quickdraw::Property.remember("several", [5])
		Quickdraw::Property.remember("several", [7])
		Quickdraw::Property.remember("several", [7])
		path = Quickdraw::Property.path("several")
		assert_equal Quickdraw::Property.saved(path), [[5], [7]]

		values = []
		failure = Quickdraw::Property::Failure.new(failures: [{ "message" => "seven", "path" => __FILE__, "line" => __LINE__ }], errors: [])
		property = Quickdraw::Property.new([integer(0..)], cases: 0, seconds: nil, key: "several") do |(n)|
			values << n
			failure if n == 7
		end

		counterexample = property.check
		assert_equal values.first(2), [5, 7]
		assert_equal counterexample.input, "7"
		assert_equal Quickdraw::Property.saved(path), [[7]]
	end

	test "ignores and deletes a saved case it can't read" do
		fixed = false
		property = proc { check(integer(0..)) { |n| assert fixed || n < 5 } }

		assert_test(failures: 1, &property)
		Dir.each_child(Quickdraw::Property.directory) { |it| File.write(File.join(Quickdraw::Property.directory, it), "not a choice") }

		fixed = true
		assert_test(passes: 1, &property)
		assert_equal Dir.children(Quickdraw::Property.directory), []
	end

	test "still reports a counterexample it can't save" do
		File.write(Quickdraw::Property.directory, "a file where the directory would be")

		runner = assert_test(failures: 1) { check(integer(0..)) { |n| assert n < 5 } }

		assert_includes message(runner), "\n\n5\n\n"
	end

	test "reports errors a case reports, as from a nested check" do
		runner = assert_test(errors: 1) do
			check(integer(0..)) { |n| check(integer(0..), cases: 5) { |m| raise "too big" if m + n > 10 } }
		end

		assert_match runner.errors.first["message"], /\Atoo big\n\n.*Counterexample/m
	end

	test "raises when filters discard too many cases, or every case before time runs out" do
		runner = assert_test(errors: 1) { check(integer.filter { false }) { nil } }
		assert_equal runner.errors.first["name"], "Quickdraw::Property::Unsatisfiable"

		runner = assert_test(errors: 1) { check(integer.filter { sleep(0.01) && false }, seconds: 0.02) { nil } }
		assert_equal runner.errors.first["name"], "Quickdraw::Property::Unsatisfiable"
	end

	test "needs a generator and a block" do
		assert_raises(ArgumentError) { check { nil } }
		assert_raises(ArgumentError) { check(integer) }
	end
end
