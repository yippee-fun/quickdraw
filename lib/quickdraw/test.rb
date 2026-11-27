# frozen_string_literal: true

class Quickdraw::Test < Quickdraw::BasicTest
	include Quickdraw::Assertions
	include Quickdraw::Stubs
	include Quickdraw::Generators
	# For fuzz, in the class body.
	extend Quickdraw::Generators

	# Defines a test that checks the block with values from the generators, as
	# `check` does, and that `quickdraw fuzz` fuzzes for longer, guided by the
	# code it reaches. Without generators, the block is an ordinary test that
	# calls `check`, so it can set up before its cases and check something after
	# them all, and `quickdraw fuzz` fuzzes its first property. Under `quickdraw
	# fuzz`, a case that runs for `hang_after` seconds hangs, in place of
	# --timeout's.
	def self.fuzz(*arguments, cases: 100, timeout: nil, hang_after: nil, mutation: true, &block)
		description = arguments.shift unless Quickdraw::Generator === arguments.first
		raise ::ArgumentError, "fuzz needs a block." unless block
		raise ::ArgumentError, "fuzz needs a generator, as in fuzz(\"parses anything\", bytes) { |input| … }, or a block that calls check." if arguments.empty? && block.arity != 0
		raise ::ArgumentError, "hang_after needs a positive number of seconds." if hang_after && !(Numeric === hang_after && hang_after.positive?)

		(@fuzz_targets ||= {}.compare_by_identity)[block] = FuzzTarget.new(generators: arguments, cases:, hang_after:)
		test(description, timeout:, mutation:, &block)
	end

	# A test fuzz defined: its generators, if its block is a property's, and how many cases it checks.
	FuzzTarget = Data.define(:generators, :cases, :hang_after)

	# The FuzzTarget of the test that fuzz defined with `block`, if it did.
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
			# Context a case adds is only its own.
			contexts = @contexts
			@contexts = contexts&.dup
			block.call(*values)
			recorder.failure
		rescue StandardError, ScriptError, SystemStackError => error
			# Through the test, which adds its context, to the case's recorder.
			error!(error)
			recorder.failure
		ensure
			@contexts = contexts
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
		if (target = self.class.fuzz_target(@block)) && target.generators.any?
			check(*target.generators, cases: target.cases) { |*values| instance_exec(*values, &@block) }
		else
			super
		end
	end

	# A new, empty directory that's removed after the test. Its real, absolute
	# path, since on some systems the temporary directory is behind a symlink, and
	# a test may change directory before cleanup.
	def tmpdir
		path = File.join(Quickdraw.temporary_directory, "quickdraw-#{Process.pid}-#{Random.urandom(8).unpack1('H*')}")
		Dir.mkdir(path)
		path = File.realpath(path)
		defer { Quickdraw.remove_tree(path) }
		path
	end
end
