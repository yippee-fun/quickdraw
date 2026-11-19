# frozen_string_literal: true

class Quickdraw::Configuration
	def initialize
		@before_forking_callbacks = []
		@after_forking_callbacks = []
	end

	attr_reader :before_forking_callbacks
	attr_reader :after_forking_callbacks

	# Runs once in the loader, after config and helpers load and before workers fork.
	def before_forking(&block)
		@before_forking_callbacks << block
	end

	# Runs in each worker after it forks. `QUICKDRAW_WORKER` holds the worker’s index.
	def after_forking(&block)
		@after_forking_callbacks << block
	end
end
