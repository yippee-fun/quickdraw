# frozen_string_literal: true

# Runs Rails' test helpers, which assert as Minitest does, for a Quickdraw test,
# whose assertions they then make. A subclass includes the helpers, then
# Assertions, which must come before them.
class Quickdraw::Rails::MinitestBridge
	FAILED = Object.new.freeze

	# Defines each helper on `helpers`, a module for tests, to call the test's bridge.
	def self.forward(helpers, *names)
		names.each do |name|
			helpers.define_method(name) do |*arguments, **options, &block|
				rails_helpers.call(name, *arguments, **options, &block)
			end
		end
	end

	def initialize(test)
		@test = test
	end

	def before_setup = nil
	def after_teardown = nil

	# A failed assertion stops the helper, as in Minitest, but not the test.
	def call(name, ...)
		catch(FAILED) { public_send(name, ...) }
	end

	module Assertions
		private def assert(value, message = nil)
			@test.assert(value) { message || "expected #{value.inspect} to be truthy" }
			throw FAILED unless value
		end

		private def assert_equal(expected, actual, message = nil)
			assert(expected == actual, message || "expected #{actual.inspect} to be #{expected.inspect}")
		end

		# Rails' warns of exceptions through Minitest, which isn't loaded.
		private def _assert_nothing_raised_or_warn(_assertion) = yield
	end
end
