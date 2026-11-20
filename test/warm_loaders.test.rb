# frozen_string_literal: true

class WarmLoadersTest < Quickdraw::Test
	BUNDLE = ["/app/gems/greeting/Gemfile", "/app/gems/greeting/Gemfile.lock"].freeze

	test "a bundle is touched by a change to one of its files, or to a directory holding them" do
		assert Quickdraw::WarmLoaders.touched?(BUNDLE, ["/app/gems/greeting/Gemfile.lock"])
		assert Quickdraw::WarmLoaders.touched?(BUNDLE, ["/app/gems/greeting"])
		assert Quickdraw::WarmLoaders.touched?(BUNDLE, ["/app/lib/a.rb", "/app/gems"])
	end

	test "a bundle isn't touched by other changes" do
		refute Quickdraw::WarmLoaders.touched?(BUNDLE, ["/app/gems/greeting/lib/greeting.rb"])
		refute Quickdraw::WarmLoaders.touched?(BUNDLE, ["/app/gems/greet"])
		refute Quickdraw::WarmLoaders.touched?(BUNDLE, [])
	end
end
