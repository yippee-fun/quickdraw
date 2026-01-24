# frozen_string_literal: true

begin
	require "rspec/expectations"
rescue LoadError
	raise LoadError.new("You need to add `rspec-expectations` to your Gemfile")
end

module Quickdraw::RSpec
	autoload :Spec, "quickdraw/rspec/spec"
	autoload :Matchers, "quickdraw/rspec/matchers"
	autoload :Expectation, "quickdraw/rspec/expectation"

	def self.describe(*descriptions, &)
		Spec.describe(*descriptions, &)
	end

	def self.shared_examples(name, metadata = nil, &block)
		global_shared_examples[name] = { block:, metadata: }
	end

	def self.global_shared_examples
		@shared_examples ||= {}
	end
end
