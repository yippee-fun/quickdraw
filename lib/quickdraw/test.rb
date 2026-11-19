# frozen_string_literal: true

class Quickdraw::Test < Quickdraw::BasicTest
	include Quickdraw::Assertions

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
