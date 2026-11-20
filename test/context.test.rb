# frozen_string_literal: true

class ContextTest < Quickdraw::Test
	test "shows the context with each failure after it" do
		runner = assert_test(failures: 3) do
			assert false
			status = 1
			context { "exit status #{status}" }
			context { { stderr: "boom" } }
			assert false
			status = 2
			assert false
		end

		first, second, third = runner.failures
		assert_nil first["context"]
		assert_equal second["context"], "exit status 1\n{\n  stderr: \"boom\",\n}"
		assert_equal third["context"], "exit status 2\n{\n  stderr: \"boom\",\n}"
	end

	test "only calls the block when something fails" do
		called = false

		assert_test(passes: 1) do
			context { called = true }
			assert true
		end

		refute called
	end

	test "shows what the block raised, rather than raising" do
		runner = assert_test(failures: 1) do
			context { raise ArgumentError, "no output" }
			assert false
		end

		assert_equal runner.failures.last["context"], "context { … } raised ArgumentError: no output"
	end

	test "shows a skip inside the block, rather than skipping the failing test" do
		runner = assert_test(failures: 1) do
			context { skip "no output" }
			assert false
		end

		assert_equal runner.failures.last["context"], "context { … } raised Quickdraw::BasicTest::Skip: no output"
		assert_nil runner.skipped
	end

	test "joins text in different encodings" do
		runner = assert_test(failures: 1) do
			context { "\xFF".b }
			context { "é" }
			assert false
		end

		assert_equal runner.failures.last["context"], "�\né"
	end

	test "shows the context with an error a property's case raises, and only that case's" do
		runner = assert_test(errors: 1) do
			context { "outside" }

			check(integer(1..1)) do |value|
				context { "case #{value}" }
				raise "boom"
			end
		end

		assert_equal runner.errors.last["context"], "outside\ncase 1"
	end

	test "doesn't show the context again for a failure inside it" do
		runner = assert_test(failures: 2) do
			context { assert(false) && "never" }
			assert false
		end

		assert_nil runner.failures.first["context"]
		assert_equal runner.failures.last["context"], "nil"
	end

	test "shows the context with an error, as it was before cleanup" do
		runner = assert_test(errors: 1) do
			log = +"started"
			defer { log.replace("cleaned up") }
			context { log }
			raise "boom"
		end

		assert_equal runner.errors.last["context"], "started"
	end

	test "shows the context with an error raised during cleanup" do
		runner = assert_test(passes: 1, errors: 1) do
			context { "the context" }
			defer { raise "cleanup failed" }
			assert true
		end

		assert_equal runner.errors.last["context"], "the context"
	end

	test "needs a block" do
		assert_raises(ArgumentError) { context }
	end
end
