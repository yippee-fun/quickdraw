# frozen_string_literal: true

module Quickdraw
	Box = Ruby::Box.new

	Box.require "difftastic"

	autoload :ArgumentError, "quickdraw/errors/argument_error"
	autoload :Assertions, "quickdraw/assertions"
	autoload :CLI, "quickdraw/cli"
	autoload :Cluster, "quickdraw/cluster"
	autoload :ConcurrentArray, "quickdraw/concurrent_array"
	autoload :ConcurrentInteger, "quickdraw/concurrent_integer"
	autoload :Configuration, "quickdraw/configuration"
	autoload :Platform, "quickdraw/platform"
	autoload :Queue, "quickdraw/queue"
	autoload :RSpecAdapter, "quickdraw/rspec_adapter"
	autoload :Runner, "quickdraw/runner"
	autoload :Test, "quickdraw/test"
	autoload :Timer, "quickdraw/timer"
	autoload :Worker, "quickdraw/worker"
	autoload :MinitestAdapter, "quickdraw/minitest_adapter"
	autoload :HTMLPrettifier, "quickdraw/html_prettifier"

	Null = Object.new.freeze
	Error = Module.new
	Config = Configuration.new

	def self.configure(&)
		yield Config
		Config.freeze
	end
end
