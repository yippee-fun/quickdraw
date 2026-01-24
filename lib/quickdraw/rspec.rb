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

	def self.describe(description = nil, &block)
		Class.new(Spec) do
			if respond_to?(:set_temporary_name)
				case description
				when Class
					set_temporary_name "(#{description.name})"
				else
					set_temporary_name "(#{description})"
				end
			end
			class_exec(&block)
		end
	end
end
