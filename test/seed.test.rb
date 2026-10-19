# frozen_string_literal: true

require "open3"
require "tmpdir"

class SeedTest < Quickdraw::Test
	QT = File.expand_path("../exe/qt", __dir__)
	RECORDER = File.expand_path("fixtures/seed/recorder.rb", __dir__)

	def run_recorder(*args, env: {})
		Dir.mktmpdir do |dir|
			log = File.join(dir, "seed.log")
			output, status = Open3.capture2e(env.merge("SEED_LOG" => log), RbConfig.ruby, QT, *args, RECORDER, chdir: dir)
			assert(status.success?) { output }

			lines = File.readlines(log).map { |it| it.split.map(&:to_i) }
			{ output:, workers: lines.group_by(&:first).values.map { |it| it.map { |_, *rest| rest } } }
		end
	end

	test "seed is readable from inside a test" do
		assert_equal seed, $quickdraw_runner.seed
	end

	test "seed is printed at the start and in the summary" do
		output = run_recorder("-p", "1", "--seed", "1234")[:output]

		assert output.start_with?("Seed: 1234\n")
		assert_includes output, "| Seed: 1234"
	end

	test "--seed sets the seed seen by tests" do
		workers = run_recorder("-p", "1", "--seed", "42")[:workers]

		assert_equal workers.flatten(1).map { |it| it[1] }.uniq, [42]
	end

	test "SEED is used when --seed is not given" do
		assert_includes run_recorder("-p", "1", env: { "SEED" => "77" })[:output], "Seed: 77"
	end

	test "--seed takes precedence over SEED" do
		assert_includes run_recorder("-p", "1", "-s", "5", env: { "SEED" => "77" })[:output], "Seed: 5"
	end

	test "a seed is generated when none is given" do
		output = run_recorder("-p", "1", env: { "SEED" => nil })[:output]

		match { output => /\ASeed: \d+$/ }
	end

	test "a SEED that is not an integer is refused" do
		output, status = Open3.capture2e({ "SEED" => "abc" }, RbConfig.ruby, QT, RECORDER, chdir: Dir.tmpdir)

		refute status.success?
		assert_includes output, "SEED must be an integer"
	end

	test "same seed gives the same order and the same rand values" do
		first = run_recorder("-p", "1", "--seed", "1234")[:workers]
		second = run_recorder("-p", "1", "--seed", "1234")[:workers]
		other = run_recorder("-p", "1", "--seed", "4321")[:workers]

		assert_equal first, second
		refute_equal first, other # with 20 tests a collision is vanishingly unlikely
	end
end
