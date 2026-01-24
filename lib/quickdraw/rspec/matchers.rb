# frozen_string_literal: true

module Quickdraw::RSpec::Matchers
	define_method :all, ::RSpec::Matchers.instance_method(:all)
	define_method :be, ::RSpec::Matchers.instance_method(:be)
	define_method :be_a, ::RSpec::Matchers.instance_method(:be_a)
	define_method :be_a_kind_of, ::RSpec::Matchers.instance_method(:be_a_kind_of)
	define_method :be_an_instance_of, ::RSpec::Matchers.instance_method(:be_an_instance_of)
	define_method :be_between, ::RSpec::Matchers.instance_method(:be_between)
	define_method :be_falsey, ::RSpec::Matchers.instance_method(:be_falsey)
	define_method :be_nil, ::RSpec::Matchers.instance_method(:be_nil)
	define_method :be_truthy, ::RSpec::Matchers.instance_method(:be_truthy)
	define_method :be_within, ::RSpec::Matchers.instance_method(:be_within)
	define_method :change, ::RSpec::Matchers.instance_method(:change)
	define_method :contain_exactly, ::RSpec::Matchers.instance_method(:contain_exactly)
	define_method :cover, ::RSpec::Matchers.instance_method(:cover)
	define_method :end_with, ::RSpec::Matchers.instance_method(:end_with)
	define_method :eq, ::RSpec::Matchers.instance_method(:eq)
	define_method :eql, ::RSpec::Matchers.instance_method(:eql)
	define_method :equal, ::RSpec::Matchers.instance_method(:equal)
	define_method :exist, ::RSpec::Matchers.instance_method(:exist)
	define_method :have_attributes, ::RSpec::Matchers.instance_method(:have_attributes)
	define_method :include, ::RSpec::Matchers.instance_method(:include)
	define_method :match, ::RSpec::Matchers.instance_method(:match)
	define_method :match_array, ::RSpec::Matchers.instance_method(:match_array)
	define_method :output, ::RSpec::Matchers.instance_method(:output)
	define_method :raise_error, ::RSpec::Matchers.instance_method(:raise_error)
	define_method :respond_to, ::RSpec::Matchers.instance_method(:respond_to)
	define_method :satisfy, ::RSpec::Matchers.instance_method(:satisfy)
	define_method :start_with, ::RSpec::Matchers.instance_method(:start_with)
	define_method :throw_symbol, ::RSpec::Matchers.instance_method(:throw_symbol)
	define_method :yield_control, ::RSpec::Matchers.instance_method(:yield_control)

	# Aliases
	alias_method :be_an, :be_a
	alias_method :be_falsy, :be_falsey
	alias_method :be_instance_of, :be_an_instance_of
	alias_method :be_kind_of, :be_a_kind_of
	alias_method :raise_exception, :raise_error

	define_method :yield_successive_args, ::RSpec::Matchers.instance_method(:yield_successive_args)
	define_method :yield_with_args, ::RSpec::Matchers.instance_method(:yield_with_args)
	define_method :yield_with_no_args, ::RSpec::Matchers.instance_method(:yield_with_no_args)
end
