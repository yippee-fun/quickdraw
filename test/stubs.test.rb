# frozen_string_literal: true

class StubsTest < Quickdraw::Test
	def greeter
		Class.new do
			def self.kind = :greeter

			def greet(name) = "Hello, #{name}"
			def shout(name) = whisper(name).upcase

			private def whisper(name) = name

			def method_missing(name, ...) = (name == :wave) ? :waving : super
			def respond_to_missing?(name, include_private) = (name == :wave) || super
		end
	end

	describe "stub" do
		test "replaces a method on one object until the test ends" do
			stubbed = greeter.new
			other = stubbed.class.new

			assert_test(passes: 2) do
				stub(stubbed, :greet) { |name| "Hi, #{name}" }
				assert_equal stubbed.greet("Joel"), "Hi, Joel"
				assert_equal other.greet("Joel"), "Hello, Joel"
			end

			assert_equal stubbed.greet("Joel"), "Hello, Joel"
		end

		test "returns a value" do
			stubbed = greeter.new
			stub(stubbed, :greet, returns: nil)

			assert_nil stubbed.greet("Joel")
		end

		test "passes on arguments, keywords and blocks" do
			stubbed = greeter.new
			stub(stubbed, :greet) { |*args, **kwargs, &block| [args, kwargs, block.call] }

			assert_equal stubbed.greet(1, { a: 2 }, b: 3) { 4 }, [[1, { a: 2 }], { b: 3 }, 4]
		end

		test "runs the block in the test" do
			stubbed = greeter.new
			stub(stubbed, :greet) { self }

			assert_same stubbed.greet, self
		end

		test "replaces a class's methods, and restores those defined on it" do
			stubbed = greeter

			assert_test(passes: 1) do
				stub(stubbed, :kind, returns: :stub)
				assert_equal stubbed.kind, :stub
			end

			assert_equal stubbed.kind, :greeter
		end

		test "keeps a private method private" do
			stubbed = greeter.new
			stub(stubbed, :whisper) { |name| "psst, #{name}" }

			assert_equal stubbed.shout("Joel"), "PSST, JOEL"
			assert_raises(NoMethodError) { stubbed.whisper("Joel") }
		end

		test "replaces a method that method_missing answers" do
			stubbed = greeter.new
			stub(stubbed, :wave, returns: :stubbed)

			assert_equal stubbed.wave, :stubbed
		end

		test "replaces an earlier stub, and restores the original" do
			stubbed = greeter.new

			assert_test(passes: 1) do
				stub(stubbed, :greet, returns: 1)
				stub(stubbed, :greet, returns: 2)
				assert_equal stubbed.greet("Joel"), 2
			end

			assert_equal stubbed.greet("Joel"), "Hello, Joel"
		end

		test "goes beneath modules prepended to the singleton class" do
			stubbed = greeter
			stubbed.singleton_class.prepend(Module.new { def kind = [:wrapped, super] })

			assert_test(passes: 2) do
				calls = spy(stubbed, :kind)
				assert_equal stubbed.kind, [:wrapped, :greeter]
				assert_equal calls.count, 1
			end

			assert_test(passes: 2) do
				stub(stubbed, :kind, returns: :stub)
				calls = spy(stubbed, :kind)
				assert_equal stubbed.kind, [:wrapped, :stub]
				assert_equal calls.count, 1
			end

			assert_equal stubbed.kind, [:wrapped, :greeter]
		end

		test "doesn't trust the object's singleton_class" do
			stubbed = greeter.new
			def stubbed.singleton_class = String

			stub(stubbed, :greet, returns: 1)

			assert_equal stubbed.greet("Joel"), 1
			refute String.method_defined?(:greet)
		end

		test "leaves nothing behind on the object" do
			stubbed = +"text"

			assert_test(passes: 1) do
				stub(stubbed, :upcase, returns: 1)
				spy(stubbed, :upcase)
				assert_equal stubbed.upcase, 1
			end

			assert_equal stubbed.singleton_methods, []
			assert_equal stubbed.singleton_class.ancestors.take_while { |it| !it.equal?(String) }, [stubbed.singleton_class]
			assert_equal Marshal.load(Marshal.dump(stubbed)), "text"
		end

		test "doesn't shadow a test's own helpers" do
			test_class = Class.new(Quickdraw::Test) do
				def patch(path) = path
				def validate = :valid
			end

			stubbed = greeter.new

			assert_test(passes: 1, test_class:) do
				stub(stubbed, :greet, returns: 1)
				assert_equal [stubbed.greet("Joel"), patch("/"), validate], [1, "/", :valid]
			end
		end

		test "is undone when the test fails, raises or skips" do
			stubbed = greeter.new

			assert_test(failures: 1) do
				stub(stubbed, :greet, returns: 1)
				assert false
			end

			assert_test(errors: 1) do
				stub(stubbed, :greet, returns: 2)
				raise "boom"
			end

			runner = assert_test do
				stub(stubbed, :greet, returns: 3)
				skip
			end

			assert runner.skipped
			assert_equal stubbed.greet("Joel"), "Hello, Joel"
		end

		test "refuses a method the object doesn't have" do
			error = assert_raises(ArgumentError) { stub(greeter.new, :missing, returns: 1) }

			assert_match error.message, /\ACan't replace missing: an instance of #<Class:0x\h+> has no such method\.\z/
		end

		test "refuses a frozen object" do
			error = assert_raises(ArgumentError) { stub(1, :succ, returns: 1) }

			assert_equal error.message, "Can't replace succ: an instance of Integer is frozen."
		end

		test "needs a block or a value, but not both" do
			assert_equal assert_raises(ArgumentError) { stub(greeter.new, :greet) }.message, "stub needs a block or returns:."
			assert_equal assert_raises(ArgumentError) { stub(greeter.new, :greet, returns: 1) { 2 } }.message, "stub takes a block or returns:, not both."
		end
	end

	describe "spy" do
		test "records calls, which still run" do
			spied = greeter.new
			block = proc { nil }
			calls = spy(spied, :greet)

			refute calls.called?
			assert_equal spied.greet("Joel", &block), "Hello, Joel"
			assert_equal calls.count, 1

			match do
				calls.calls => [{ args: ["Joel"], kwargs: {}, result: "Hello, Joel", error: nil, thread: ^(Thread.current) }]
			end

			assert_same calls.calls.first.block, block
		end

		test "records what a call raised" do
			spied = greeter.new
			calls = spy(spied, :greet)

			assert_raises(ArgumentError) { spied.greet }
			match { calls.calls => [{ args: [], result: nil, error: ArgumentError }] }
		end

		test "records calls left by throw or break" do
			spied = greeter.new
			stub(spied, :greet) { |&block| block.call }
			calls = spy(spied, :greet)

			catch(:done) { spied.greet { throw :done } }
			[1].each { spied.greet { break } }

			match { calls.calls => [{ result: nil, error: nil }, { result: nil, error: nil }] }
		end

		test "records calls from other threads" do
			spied = greeter.new
			calls = spy(spied, :greet)
			thread = Thread.new { spied.greet("Joel") }
			thread.join

			match { calls.calls => [{ thread: ^thread }] }
		end

		test "records calls answered by method_missing" do
			spied = greeter.new
			calls = spy(spied, :wave)

			assert_equal spied.wave, :waving
			match { calls.calls => [{ result: :waving }] }
		end

		test "records calls to Thread.current" do
			calls = spy(Thread, :current)
			current = Thread.current

			assert_same current, Thread.list.find { |it| it.equal?(current) }
			assert_includes calls.calls, Quickdraw::Spy::Call.new(args: [], kwargs: {}, block: nil, result: current, error: nil, thread: current)
		end

		test "records calls to a stub" do
			spied = greeter.new
			stub(spied, :greet, returns: "Hi")
			calls = spy(spied, :greet)

			assert_equal spied.greet("Joel"), "Hi"
			match { calls.calls => [{ args: ["Joel"], result: "Hi" }] }
		end

		test "keeps a private method private" do
			spied = greeter.new
			calls = spy(spied, :whisper)

			assert_equal spied.shout("Joel"), "JOEL"
			assert_raises(NoMethodError) { spied.whisper("Joel") }
			assert_equal calls.count, 1
		end

		test "is undone after the test" do
			spied = greeter.new
			calls = nil

			assert_test(passes: 1) do
				calls = spy(spied, :greet)
				spied.greet("Joel")
				assert calls.called?
			end

			spied.greet("Joel")
			assert_equal calls.count, 1
		end
	end

	describe "stub_const" do
		test "defines a missing constant until the test ends" do
			assert_test(passes: 2) do
				stub_const("QuickdrawStubbed", Module.new)
				stub_const("QuickdrawStubbed::RATE", 1)
				assert_equal QuickdrawStubbed::RATE, 1
				assert Object.const_defined?(:QuickdrawStubbed)
			end

			refute Object.const_defined?(:QuickdrawStubbed)
		end

		test "replaces a constant, and restores it" do
			namespace = Module.new
			namespace.const_set(:RATE, 1)
			namespace.const_set(:SECRET, 2)
			namespace.private_constant(:SECRET)

			assert_test(passes: 3) do
				stub_const("QuickdrawStubbed", namespace)
				stub_const("::QuickdrawStubbed::RATE", 3)
				stub_const("QuickdrawStubbed::RATE", 4)
				stub_const("QuickdrawStubbed::SECRET", 5)
				assert_equal namespace::RATE, 4
				assert_equal namespace.const_get(:SECRET), 5
				assert_raises(NameError) { namespace::SECRET }
			end

			assert_equal namespace::RATE, 1
			assert_equal namespace.const_get(:SECRET), 2
			assert_raises(NameError) { namespace::SECRET }
		end

		test "keeps a constant that's still to autoload unloaded" do
			namespace = Module.new
			namespace.autoload(:Lazy, "quickdraw_stubs_missing_file")

			assert_test(passes: 1) do
				stub_const("QuickdrawStubbed", namespace)
				stub_const("QuickdrawStubbed::Lazy", 1)
				assert_equal namespace::Lazy, 1
			end

			assert_equal namespace.autoload?(:Lazy), "quickdraw_stubs_missing_file"
		end

		test "restores a constant the test removed" do
			namespace = Module.new
			namespace.const_set(:RATE, 1)

			assert_test(passes: 1) do
				stub_const("QuickdrawStubbed", namespace)
				stub_const("QuickdrawStubbed::RATE", 2)
				namespace.__send__(:remove_const, :RATE)
				assert true
			end

			assert_equal namespace::RATE, 1
		end

		test "refuses a path that isn't a constant's" do
			assert_raises(ArgumentError) { stub_const(:RATE, 1) }
			assert_raises(ArgumentError) { stub_const("", 1) }
			assert_raises(ArgumentError) { stub_const("Quickdraw::", 1) }
			assert_raises(ArgumentError) { stub_const("Quickdraw::LIB::RATE", 1) }
			assert_raises(NameError) { stub_const("QuickdrawMissing::RATE", 1) }
			assert_raises(NameError) { stub_const("lowercase", 1) }
		end
	end

	describe "stub_env" do
		test "sets and deletes variables until the test ends" do
			stub_env("QUICKDRAW_STUBBED_SET" => "original")

			assert_test(passes: 2) do
				stub_env("QUICKDRAW_STUBBED_SET" => nil, "QUICKDRAW_STUBBED_NEW" => "new")
				stub_env("QUICKDRAW_STUBBED_NEW" => "newer")
				refute ENV.key?("QUICKDRAW_STUBBED_SET")
				assert_equal ENV["QUICKDRAW_STUBBED_NEW"], "newer"
			end

			assert_equal ENV["QUICKDRAW_STUBBED_SET"], "original"
			refute ENV.key?("QUICKDRAW_STUBBED_NEW")
		end

		test "refuses keys and values ENV can't hold" do
			assert_raises(ArgumentError) { stub_env(KEY: "value") }
			assert_raises(ArgumentError) { stub_env("KEY" => 1) }
			assert_raises(ArgumentError) { stub_env("KEY") }
		end
	end
end
