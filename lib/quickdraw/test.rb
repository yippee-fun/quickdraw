# frozen_string_literal: true

class Quickdraw::Test < Quickdraw::BasicTest
	include Quickdraw::Assertions
	include Quickdraw::Generators

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

		if (counterexample = property.check)
			counterexample.report(runner)
		else
			success!
		end

		nil
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
