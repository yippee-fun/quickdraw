# frozen_string_literal: true

class Quickdraw::Test < Quickdraw::BasicTest
	include Quickdraw::Assertions
	include Quickdraw::Generators
	# For fuzz, in the class body.
	extend Quickdraw::Generators

	# Defines a test that checks the block with values from the generators, as
	# `check` does, and that `quickdraw fuzz` fuzzes for longer, guided by the
	# code it reaches.
	def self.fuzz(*arguments, cases: 100, timeout: nil, &block)
		description = arguments.shift unless Quickdraw::Generator === arguments.first
		raise ::ArgumentError, "fuzz needs a generator, as in fuzz(\"parses anything\", bytes) { |input| … }." if arguments.empty?
		raise ::ArgumentError, "fuzz needs a block." unless block

		(@fuzz_targets ||= {}.compare_by_identity)[block] = [arguments, cases]
		test(description, timeout:, &block)
	end

	# The generators and case count of the test that fuzz defined with `block`, if it did.
	def self.fuzz_target(block) = @fuzz_targets&.[](block)

	# Runs the block with values from the generators, `cases` times or until
	# `seconds` have passed, and reports the simplest values that fail it.
	def check(*generators, cases: 100, seconds: nil, &block)
		raise ::ArgumentError, "check needs a block." unless block

		runner = @runner
		@checks = (@checks || 0) + 1
		path, line = @block.source_location
		class_name = self.class.name&.gsub(/#<Module:0x\h+>::/, "")
		# By name, so editing the file doesn't lose the saved case, unless the test has none.
		name = @description || line
		key = "#{path.delete_prefix("#{Quickdraw::ROOT}/")}\0#{class_name}\0#{name}\0#{@checks}"

		property = Quickdraw::Property.new(generators, cases:, seconds:, key:) do |values|
			recorder = Quickdraw::Property::Recorder.new
			@runner = recorder
			block.call(*values)
			recorder.failure
		rescue StandardError, ScriptError, SystemStackError => error
			recorder.failure(error)
		ensure
			@runner = runner
		end

		# Under `quickdraw fuzz`, the test's first property is fuzzed instead.
		fuzzer = Quickdraw::Fuzz.claim

		if (counterexample = fuzzer ? fuzzer.call(property) : property.check)
			counterexample.report(runner)
		else
			success!
		end

		nil
	end

	private def run_block
		case self.class.fuzz_target(@block)
		in [generators, cases] then check(*generators, cases:) { |*values| instance_exec(*values, &@block) }
		in nil then super
		end
	end

	# A new, empty directory that's removed after the test. Its real, absolute
	# path, since on some systems the temporary directory is behind a symlink, and
	# a test may change directory before cleanup.
	def tmpdir
		path = File.join(File.expand_path(ENV.fetch("TMPDIR", "/tmp")), "quickdraw-#{Process.pid}-#{rand(2 ** 64).to_s(36)}")
		Dir.mkdir(path)
		path = File.realpath(path)
		defer { Quickdraw.remove_tree(path) }
		path
	end
end
