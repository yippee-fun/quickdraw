# frozen_string_literal: true

class Quickdraw::Configuration
	# Test files matching any of `patterns` (globs relative to the project, such
	# as "test/browser/**/*.test.rb") run in processes of their own, booted with
	# `setup` as well as the rest of the config. Other tests never see what
	# `setup` loads.
	Group = Data.define(:name, :patterns, :setup) do
		def match?(path) = patterns.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
	end

	def initialize
		@before_forking_callbacks = []
		@after_forking_callbacks = []
		@groups = []
		@timeout = 300
	end

	attr_reader :before_forking_callbacks
	attr_reader :after_forking_callbacks
	attr_reader :groups

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

	# Defines a group (see Group). A file in more than one group goes in the
	# first. The block runs after the before_forking callbacks.
	def group(name, *patterns, &setup)
		name = name.to_s
		raise ArgumentError, "The #{name} group needs a pattern for its files, such as \"test/#{name}/**/*.test.rb\"." if patterns.empty?
		raise ArgumentError, "There’s already a group named #{name}." if @groups.any? { |group| group.name == name }

		@groups << Group.new(name:, patterns: patterns.map(&:to_s).freeze, setup:)
	end
end
