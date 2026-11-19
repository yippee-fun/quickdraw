# frozen_string_literal: true

class TmpdirTest < Quickdraw::Test
	test "gives an empty directory at its real path" do
		directory = tmpdir

		assert Dir.exist?(directory)
		assert_equal Dir.children(directory), []
		assert_equal File.realpath(directory), directory
	end

	test "gives a new directory each time" do
		refute_equal tmpdir, tmpdir
	end

	test "removes the directory and its contents after the test" do
		directory = nil

		assert_test(passes: 1) do
			directory = tmpdir
			Dir.mkdir(File.join(directory, "nested"))
			File.write(File.join(directory, "nested", "file"), "contents")
			assert true
		end

		refute Dir.exist?(directory)
	end

	test "removes read-only directories in it" do
		directory = nil

		assert_test(passes: 1) do
			directory = tmpdir
			locked = File.join(directory, "locked")
			Dir.mkdir(locked)
			File.write(File.join(locked, "file"), "contents")
			File.chmod(0o555, locked)
			assert true
		end

		refute Dir.exist?(directory)
	end

	test "doesn't follow a symlink given with a trailing slash" do
		outside = tmpdir
		File.write(File.join(outside, "keep"), "contents")
		link = File.join(tmpdir, "link")
		File.symlink(outside, link)

		Quickdraw.remove_tree("#{link}/")

		refute File.exist?(link)
		assert File.exist?(File.join(outside, "keep"))
	end

	test "doesn't follow symlinks out of the directory when removing it" do
		outside = tmpdir
		File.write(File.join(outside, "keep"), "contents")

		assert_test(passes: 1) do
			File.symlink(outside, File.join(tmpdir, "link"))
			assert true
		end

		assert File.exist?(File.join(outside, "keep"))
	end
end
