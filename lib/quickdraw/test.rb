# frozen_string_literal: true

class Quickdraw::Test < Quickdraw::BasicTest
	include Quickdraw::Assertions
	include Quickdraw::Stubs
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

		# The test's, or the case of a property this checks within.
		test_runner = runner
		@checks = (@checks || 0) + 1
		path, line = @block.source_location
		class_name = self.class.name&.then { |name| Quickdraw.utf8(name) }&.gsub(/#<Module:0x\h+>::/, "")
		# By name, so editing the file doesn't lose the saved case, unless the test has none.
		name = @description || line
		occurrence = self.class.occurrence(@block)
		name = "#{name}\0#{occurrence}" if occurrence > 1
		key = "#{path.delete_prefix("#{Quickdraw::ROOT}/")}\0#{class_name}\0#{name}\0#{@checks}"

		# Each case's assertions go to its own recorder through fiber storage,
		# which only the case's fibers and the threads they start inherit, so
		# another thread's can't fail a case. One a case's thread makes after it
		# ends goes to the test.
		property = Quickdraw::Property.new(generators, cases:, seconds:, key:) do |values|
			recorder = Quickdraw::Property::Recorder.new
			outer = Fiber[:quickdraw_case]
			# With the test, so another test run inside the case records its own.
			Fiber[:quickdraw_case] = [self, recorder]
			block.call(*values)
			recorder.failure
		rescue StandardError, ScriptError, SystemStackError => error
			recorder.failure(error)
		ensure
			Fiber[:quickdraw_case] = outer
			recorder.close(test_runner)
		end

		# Under `quickdraw fuzz`, the test's first property is fuzzed instead.
		fuzzer = Quickdraw::Fuzz.claim

		if (counterexample = fuzzer ? fuzzer.call(property) : property.check)
			counterexample.report(test_runner)
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
