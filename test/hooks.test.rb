# frozen_string_literal: true

# Whether a class has hooks to run can't be remembered: each of these changes
# it after the class has already run a test.
class HooksTest < Quickdraw::Test
	def run_hooks(test_class, ran)
		assert_test(passes: 1, test_class:) do
			ran << :test
			assert true
		end
	end

	test "runs setup and teardown around the test" do
		ran = []

		test_class = Class.new(Quickdraw::Test) do
			define_method(:setup) { ran << :setup }
			define_method(:teardown) { ran << :teardown }
		end

		run_hooks(test_class, ran)

		assert_equal ran, [:setup, :test, :teardown]
	end

	test "runs hooks an ancestor defines after its subclass has run a test" do
		ran = []
		parent = Class.new(Quickdraw::Test)
		child = Class.new(parent)
		run_hooks(child, [])

		parent.define_method(:setup) { ran << :setup }
		parent.define_method(:teardown) { ran << :teardown }
		run_hooks(child, ran)

		assert_equal ran, [:setup, :test, :teardown]
	end

	test "runs hooks from a module an ancestor includes or prepends after its subclass has run a test" do
		ran = []
		parent = Class.new(Quickdraw::Test)
		child = Class.new(parent)
		run_hooks(child, [])

		parent.include(Module.new { define_method(:setup) { ran << :setup } })
		parent.prepend(Module.new { define_method(:teardown) { ran << :teardown } })
		run_hooks(child, ran)

		assert_equal ran, [:setup, :test, :teardown]
	end

	test "runs hooks an included module defines after a test has run" do
		ran = []
		helpers = Module.new
		test_class = Class.new(Quickdraw::Test) { include helpers }
		run_hooks(test_class, [])

		helpers.define_method(:setup) { ran << :setup }
		helpers.define_method(:teardown) { ran << :teardown }
		run_hooks(test_class, ran)

		assert_equal ran, [:setup, :test, :teardown]
	end

	test "runs hooks a class that replaces method_added defines after a test has run" do
		ran = []
		test_class = Class.new(Quickdraw::Test) { def self.method_added(_name) = nil }
		run_hooks(test_class, [])

		test_class.define_method(:setup) { ran << :setup }
		run_hooks(test_class, ran)

		assert_equal ran, [:setup, :test]
	end

	test "runs a teardown the test itself extends in" do
		ran = []
		cleanup = Module.new { define_method(:teardown) { ran << :teardown } }

		assert_test(passes: 1) do
			extend cleanup
			assert true
		end

		assert_equal ran, [:teardown]
	end

	test "stops running hooks once they're removed" do
		ran = []
		test_class = Class.new(Quickdraw::Test) { define_method(:setup) { ran << :setup } }
		run_hooks(test_class, ran)

		test_class.remove_method(:setup)
		run_hooks(test_class, ran)

		assert_equal ran, [:setup, :test, :test]
	end

	test "reports an error in teardown and still runs deferred blocks" do
		deferred = false
		test_class = Class.new(Quickdraw::Test) { def teardown = raise("teardown failed") }

		runner = assert_test(passes: 1, errors: 1, test_class:) do
			defer { deferred = true }
			assert true
		end

		assert deferred
		assert_equal runner.errors.map { |error| error["message"] }, ["teardown failed"]
	end

	test "doesn't run the test, but does run teardown, when setup raises" do
		ran = []

		test_class = Class.new(Quickdraw::Test) do
			define_method(:setup) { raise "setup failed" }
			define_method(:teardown) { ran << :teardown }
		end

		assert_test(errors: 1, test_class:) { ran << :test }

		assert_equal ran, [:teardown]
	end
end
