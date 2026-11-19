# frozen_string_literal: true

class Quickdraw::Configuration
	def initialize
		@before_forking_callbacks = []
		@after_forking_callbacks = []
		@timeout = 300
	end

	attr_reader :before_forking_callbacks
	attr_reader :after_forking_callbacks

	# Seconds before a test times out, or nil for never. A test can set its own
	# with `test("…", timeout: 5)`.
	attr_accessor :timeout

	# Runs once in the loader, after config and helpers load and before workers fork.
	def before_forking(&block)
		@before_forking_callbacks << block
	end

	# Runs in each worker after it forks. `QUICKDRAW_WORKER` holds the worker’s index.
	def after_forking(&block)
		@after_forking_callbacks << block
	end
end
