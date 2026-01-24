# frozen_string_literal: true

begin
	require "minitest/assertions"
rescue LoadError
	raise LoadError.new("You need to add `minitest` to your Gemfile")
end

module Quickdraw
	module Minitest
		class Test < Quickdraw::BasicTest
			def self.method_added(name)
				name = name.to_s

				return unless name.start_with?("test_")

				location = instance_method(name).source_location

				class_eval(<<~RUBY, *location)
				  test("#{name[5..].tr('_', ' ')}") do
						#{name}
					end
				RUBY
			end

			def assert(value, message = nil)
				case message
				when nil
					super(value) { yield }
				when Proc
					super(value, &message)
				else
					super(value) { message }
				end
			end

			def refute(value, message = nil)
				super(value) { message || yield }
			end

			# Fails unless obj is empty.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_empty-instance_method)
			def assert_empty(obj, message = nil) = nil
			define_method :assert_empty, ::Minitest::Assertions.instance_method(:assert_empty)

			# Fails unless exp == act printing the difference between the two, if possible.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_equal-instance_method)
			def assert_equal(exp, act, msg = nil) = nil
			define_method :assert_equal, ::Minitest::Assertions.instance_method(:assert_equal)

			# For comparing Floats. Fails unless exp and act are within delta of each other.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_in_delta-instance_method)
			def assert_in_delta(exp, act, delta = 0.001, msg = nil) = nil
			define_method :assert_in_delta, ::Minitest::Assertions.instance_method(:assert_in_delta)

			# For comparing Floats. Fails unless exp and act have a relative error less than epsilon.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_in_epsilon-instance_method)
			def assert_in_epsilon(exp, act, epsilon = 0.001, msg = nil) = nil
			define_method :assert_in_epsilon, ::Minitest::Assertions.instance_method(:assert_in_epsilon)

			# Fails unless collection includes obj.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_includes-instance_method)
			def assert_includes(collection, obj, msg = nil) = nil
			define_method :assert_includes, ::Minitest::Assertions.instance_method(:assert_includes)

			# Fails unless obj is an instance of cls.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_instance_of-instance_method)
			def assert_instance_of(cls, obj, msg = nil) = nil
			define_method :assert_instance_of, ::Minitest::Assertions.instance_method(:assert_instance_of)

			# Fails unless obj is a kind of cls.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_kind_of-instance_method)
			def assert_kind_of(cls, obj, msg = nil) = nil
			define_method :assert_kind_of, ::Minitest::Assertions.instance_method(:assert_kind_of)

			# Fails unless matcher =~ obj.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_match-instance_method)
			def assert_match(matcher, obj, msg = nil) = nil
			define_method :assert_match, ::Minitest::Assertions.instance_method(:assert_match)

			# Fails unless obj is nil.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_nil-instance_method)
			def assert_nil(obj, msg = nil) = nil
			define_method :assert_nil, ::Minitest::Assertions.instance_method(:assert_nil)

			# For testing with binary operators.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_operator-instance_method)
			def assert_operator(o1, op, o2 = nil, msg = nil) = nil
			define_method :assert_operator, ::Minitest::Assertions.instance_method(:assert_operator)

			# Fails unless path exists.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_path_exists-instance_method)
			def assert_path_exists(path, msg = nil) = nil
			define_method :assert_path_exists, ::Minitest::Assertions.instance_method(:assert_path_exists)

			# For testing with pattern matching (only supported with Ruby 3.0 and later).
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_pattern-instance_method)
			def assert_pattern(&block) = nil
			define_method :assert_pattern, ::Minitest::Assertions.instance_method(:assert_pattern)

			# For testing with predicates.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_predicate-instance_method)
			def assert_predicate(o1, op, msg = nil) = nil
			define_method :assert_predicate, ::Minitest::Assertions.instance_method(:assert_predicate)

			# Fails unless the block raises one of exp. Returns the exception matched.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_raises-instance_method)
			def assert_raises(*exp, &block) = nil
			define_method :assert_raises, ::Minitest::Assertions.instance_method(:assert_raises)

			# Fails unless obj responds to meth.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_respond_to-instance_method)
			def assert_respond_to(obj, meth, msg = nil) = nil
			define_method :assert_respond_to, ::Minitest::Assertions.instance_method(:assert_respond_to)

			# Fails unless exp and act are #equal?
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_same-instance_method)
			def assert_same(exp, act, msg = nil) = nil
			define_method :assert_same, ::Minitest::Assertions.instance_method(:assert_same)

			# Fails unless the block throws sym.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#assert_throws-instance_method)
			def assert_throws(sym, msg = nil, &block) = nil
			define_method :assert_throws, ::Minitest::Assertions.instance_method(:assert_throws)

			# Fails if obj is empty.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#refute_empty-instance_method)
			def refute_empty(obj, msg = nil) = nil
			define_method :refute_empty, ::Minitest::Assertions.instance_method(:refute_empty)

			# Fails if exp == act.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#refute_equal-instance_method)
			def refute_equal(exp, act, msg = nil) = nil
			define_method :refute_equal, ::Minitest::Assertions.instance_method(:refute_equal)

			# For comparing Floats. Fails if exp is within delta of act.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#refute_in_delta-instance_method)
			def refute_in_delta(exp, act, delta = 0.001, msg = nil) = nil
			define_method :refute_in_delta, ::Minitest::Assertions.instance_method(:refute_in_delta)

			# For comparing Floats. Fails if exp and act have a relative error less than epsilon.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#refute_in_epsilon-instance_method)
			def refute_in_epsilon(a, b, epsilon = 0.001, msg = nil) = nil
			define_method :refute_in_epsilon, ::Minitest::Assertions.instance_method(:refute_in_epsilon)

			# Fails if collection includes obj.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#refute_includes-instance_method)
			def refute_includes(collection, obj, msg = nil) = nil
			define_method :refute_includes, ::Minitest::Assertions.instance_method(:refute_includes)

			# Fails if obj is an instance of cls.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#refute_instance_of-instance_method)
			def refute_instance_of(cls, obj, msg = nil) = nil
			define_method :refute_instance_of, ::Minitest::Assertions.instance_method(:refute_instance_of)

			# Fails if obj is a kind of cls.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#refute_kind_of-instance_method)
			def refute_kind_of(cls, obj, msg = nil) = nil
			define_method :refute_kind_of, ::Minitest::Assertions.instance_method(:refute_kind_of)

			# Fails if matcher =~ obj.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#refute_match-instance_method)
			def refute_match(matcher, obj, msg = nil) = nil
			define_method :refute_match, ::Minitest::Assertions.instance_method(:refute_match)

			# Fails if obj is nil.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#refute_nil-instance_method)
			def refute_nil(obj, msg = nil) = nil
			define_method :refute_nil, ::Minitest::Assertions.instance_method(:refute_nil)

			# Fails if o1 is not op o2.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#refute_operator-instance_method)
			def refute_operator(o1, op, o2 = nil, msg = nil) = nil
			define_method :refute_operator, ::Minitest::Assertions.instance_method(:refute_operator)

			# Fails if path exists.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#refute_path_exists-instance_method)
			def refute_path_exists(path, msg = nil) = nil
			define_method :refute_path_exists, ::Minitest::Assertions.instance_method(:refute_path_exists)

			# For testing with pattern matching (only supported with Ruby 3.0 and later).
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#refute_pattern-instance_method)
			def refute_pattern(&block) = nil
			define_method :refute_pattern, ::Minitest::Assertions.instance_method(:refute_pattern)

			# For testing with predicates.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#refute_predicate-instance_method)
			def refute_predicate(o1, op, msg = nil) = nil
			define_method :refute_predicate, ::Minitest::Assertions.instance_method(:refute_predicate)

			# Fails if obj responds to the message meth.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#refute_respond_to-instance_method)
			def refute_respond_to(obj, meth, msg = nil) = nil
			define_method :refute_respond_to, ::Minitest::Assertions.instance_method(:refute_respond_to)

			# Fails if exp is the same (by object identity) as act.
			# [Docs](https://www.rubydoc.info/gems/minitest/5.25.4/Minitest/Assertions#refute_same-instance_method)
			def refute_same(exp, act, msg = nil) = nil
			define_method :refute_same, ::Minitest::Assertions.instance_method(:refute_same)

			private define_method :message, ::Minitest::Assertions.instance_method(:message)
			private define_method :diff, ::Minitest::Assertions.instance_method(:diff)
			private define_method :things_to_diff, ::Minitest::Assertions.instance_method(:things_to_diff)
			private define_method :mu_pp_for_diff, ::Minitest::Assertions.instance_method(:mu_pp_for_diff)
			private define_method :mu_pp, ::Minitest::Assertions.instance_method(:mu_pp)

			def flunk(message)
				failure! { message }
			end

			def pass
				success!
			end
		end
	end
end
