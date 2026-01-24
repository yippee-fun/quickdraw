# frozen_string_literal: true

class Quickdraw::RSpec::Expectation
	def initialize(subject, context:)
		@subject = subject
		@context = context
	end

	def to(matcher)
		assert(matcher.matches?(@subject)) do
			if matcher.respond_to?(:failure_message)
				matcher.failure_message
			else
				"Failure"
			end
		end
	end

	def not_to(matcher)
		refute(matcher.matches?(@subject)) do
			if matcher.respond_to?(:failure_message_when_negated)
				matcher.failure_message_when_negated
			else
				"Failure"
			end
		end
	end

		private

	def assert(...)
		@context.assert(...)
	end

	def refute(...)
		@context.refute(...)
	end
end
