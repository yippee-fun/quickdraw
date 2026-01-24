# frozen_string_literal: true

begin
	require "rspec/expectations"
rescue LoadError
	raise LoadError.new("You need to add `rspec-expectations` to your Gemfile")
end

module Quickdraw::RSpec
	autoload :Matchers, "quickdraw/rspec/matchers"
	autoload :Expectation, "quickdraw/rspec/expectation"
	autoload :Spec, "quickdraw/rspec/spec"

	def self.describe(description = nil, &)
		Spec.describe(description, &)
	end
end
