# frozen_string_literal: true

class KillMatrixTest < Quickdraw::Test
	Baseline = Quickdraw::Mutation::Runner::Baseline
	Job = Quickdraw::Mutation::Runner::Job
	Mutant = Data.define(:id)

	def baseline(index) = Baseline.new(path: "a.test.rb", index:, name: "test #{index}", line: index + 1, status: "passed", duration: 0.001, lines: {})

	def job(id, *indices) = Job.new(mutant: Mutant.new(id:), tests: indices.map { |index| baseline(index) }, seconds: 1)

	def row(*killed, complete: true) = { "killed" => killed.map { |index| ["a.test.rb", index] }, "ran" => 0, "complete" => complete }

	test "a test that ran in complete rows and killed nothing is blind" do
		matrix = Quickdraw::Mutation::KillMatrix.new([[job(0, 0, 1), row(0)], [job(1, 0, 1), row(0)]])

		assert_equal matrix.blind.map { |entry| [entry.test.index, entry.count] }, [[1, 2]]
	end

	test "a test that only ran in incomplete rows isn't blind" do
		matrix = Quickdraw::Mutation::KillMatrix.new([[job(0, 0, 1), row(0, complete: false)]])

		assert_equal matrix.blind, []
		assert_equal matrix.incomplete, 1
	end

	test "a test is redundant if another test killed each mutant it killed, judged one test at a time" do
		matrix = Quickdraw::Mutation::KillMatrix.new([[job(0, 0, 1, 2), row(0, 1)], [job(1, 0, 1, 2), row(1, 2)]])

		# Any one could go, but not all three.
		assert_equal matrix.redundant.map { |entry| [entry.test.index, entry.count] }, [[0, 1], [1, 2], [2, 1]]
	end

	test "a test that killed a mutant no other test killed isn't redundant" do
		matrix = Quickdraw::Mutation::KillMatrix.new([[job(0, 0, 1), row(0, 1)], [job(1, 0, 1), row(1)]])

		assert_equal matrix.redundant.map { |entry| entry.test.index }, [0]
	end

	test "a kill in an incomplete row isn't known to be shared" do
		matrix = Quickdraw::Mutation::KillMatrix.new([[job(0, 0, 1), row(0, 1, complete: false)]])

		assert_equal matrix.redundant, []
	end

	test "mutants that didn't run have no row" do
		matrix = Quickdraw::Mutation::KillMatrix.new([[job(0, 0), nil]])

		assert_equal [matrix.blind, matrix.redundant, matrix.incomplete], [[], [], 0]
	end
end
