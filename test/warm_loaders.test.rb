# frozen_string_literal: true

class WarmLoadersTest < Quickdraw::Test
	BUNDLE = ["/app/gems/greeting/Gemfile", "/app/gems/greeting/Gemfile.lock"].freeze

	test "a bundle is touched by a change to one of its files, or to a directory holding them" do
		assert Quickdraw::WarmLoaders.touched?(BUNDLE, ["/app/gems/greeting/Gemfile.lock"])
		assert Quickdraw::WarmLoaders.touched?(BUNDLE, ["/app/gems/greeting"])
		assert Quickdraw::WarmLoaders.touched?(BUNDLE, ["/app/lib/a.rb", "/app/gems"])
	end

	test "a snapshot finds the files that changed, appeared or went" do
		directory = tmpdir
		changed, same, gone, missing = ["changed.rb", "same.rb", "gone.rb", "missing.rb"].map { |name| File.join(directory, name) }
		[changed, same, gone].each { |path| File.write(path, "1") }
		snapshot = Quickdraw::WarmLoaders::Snapshot.new([changed, same, gone, missing])

		assert_equal snapshot.changed, []

		File.write(changed, "22")
		File.delete(gone)
		File.write(missing, "1")

		assert_equal snapshot.changed, [changed, gone, missing]
	end

	test "a snapshot counts what changed since a time as changed, but not what was missing" do
		directory = tmpdir
		before, after, missing = ["before.rb", "after.rb", "missing.rb"].map { |name| File.join(directory, name) }
		File.write(before, "1")
		File.utime(Time.now - 60, Time.now - 60, before)
		since = Time.now - 30
		File.write(after, "1")

		assert_equal Quickdraw::WarmLoaders::Snapshot.new([before, after, missing], since:).changed, [after]
	end

	test "a bundle isn't touched by other changes" do
		refute Quickdraw::WarmLoaders.touched?(BUNDLE, ["/app/gems/greeting/lib/greeting.rb"])
		refute Quickdraw::WarmLoaders.touched?(BUNDLE, ["/app/gems/greet"])
		refute Quickdraw::WarmLoaders.touched?(BUNDLE, [])
	end
end
