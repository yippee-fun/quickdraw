# frozen_string_literal: true

module Quickdraw
	Box = Ruby::Box.new

	autoload :CLI, "quickdraw/cli"
	autoload :Test, "quickdraw/test"
	autoload :Queue, "quickdraw/queue"
	autoload :Timer, "quickdraw/timer"
	autoload :Runner, "quickdraw/runner"
	autoload :Worker, "quickdraw/worker"
	autoload :Cluster, "quickdraw/cluster"
	autoload :Platform, "quickdraw/platform"
	autoload :Assertions, "quickdraw/assertions"
	autoload :RSpecAdapter, "quickdraw/rspec_adapter"
	autoload :ArgumentError, "quickdraw/errors/argument_error"
	autoload :Configuration, "quickdraw/configuration"
	autoload :HTMLPrettifier, "quickdraw/html_prettifier"
	autoload :ConcurrentArray, "quickdraw/concurrent_array"
	autoload :MinitestAdapter, "quickdraw/minitest_adapter"
	autoload :ConcurrentInteger, "quickdraw/concurrent_integer"

	Null = Object.new.freeze
	Error = Module.new
	Config = Configuration.new

	def self.configure(&)
		yield Config
		Config.freeze
	end
end
