# frozen_string_literal: true

require "stringio"

class FormattingTest < Quickdraw::Test
	class Formatter
		include Quickdraw::Reporters::Formatting

		def initialize(io) = @io = io

		public :fit, :indent, :user_backtrace, :raised_in_quickdraw?
	end

	def terminal = StringIO.new.tap { |io| def io.tty? = true }
	def formatter(io) = Formatter.new(io)

	def setup
		stub_env("CI" => nil, "GITHUB_ACTIONS" => nil)
	end

	test "cuts long lines short in a terminal, saying how much was left out" do
		text = "short\n#{'x' * 600}\n"

		assert_equal formatter(terminal).fit(text), "short\n#{'x' * 500}… 100 more characters (shown when the output isn’t a terminal)\n"
	end

	test "keeps colour codes out of the count, and resets the colour where it cuts" do
		text = "\e[32m#{'x' * 600}\e[0m"

		assert_equal formatter(terminal).fit(text), "\e[32m#{'x' * 500}\e[0m… 100 more characters (shown when the output isn’t a terminal)"
	end

	test "cuts each line a carriage return ends on its own" do
		assert_equal formatter(terminal).fit("#{'x' * 400}\r#{'y' * 400}"), "#{'x' * 400}\n#{'y' * 400}"
	end

	test "shows long lines in full when the output isn't a terminal" do
		text = "x" * 50_000

		assert_equal formatter(StringIO.new).fit(text), text
	end

	test "shows long lines in full in CI, even on a terminal" do
		stub_env("CI" => "true")
		text = "x" * 50_000

		assert_equal formatter(terminal).fit(text), text
	end

	test "cuts absurdly long lines anywhere" do
		limit = Quickdraw::Reporters::Formatting::LOG_LINE_LIMIT

		assert_equal formatter(StringIO.new).fit("x" * (limit + 5)), "#{'x' * limit}… 5 more characters"
	end

	test "counts as CI with CI set, or under GitHub Actions" do
		refute Quickdraw::Reporters.ci?

		stub_env("CI" => "false")
		refute Quickdraw::Reporters.ci?

		stub_env("CI" => "1")
		assert Quickdraw::Reporters.ci?

		stub_env("CI" => nil, "GITHUB_ACTIONS" => "true")
		assert Quickdraw::Reporters.ci?
	end

	test "indents every line, including those after a carriage return" do
		assert_equal formatter(StringIO.new).indent("FAILED 3 tests\rERROR isolated 0\r\n\nend", 2), "  FAILED 3 tests\n  ERROR isolated 0\n\n  end"
	end

	test "drops Quickdraw's frames from a backtrace" do
		library = "#{Quickdraw::LIB}/quickdraw/basic_test.rb:10:in 'run'"
		frames = [library, "test/a.test.rb:3:in 'block'", library]

		assert_equal formatter(StringIO.new).user_backtrace(frames), ["test/a.test.rb:3:in 'block'"]
		refute formatter(StringIO.new).raised_in_quickdraw?(frames)
	end

	test "keeps the first of Quickdraw's frames when they're all there are" do
		frames = (1..20).map { |line| "#{Quickdraw::LIB}/quickdraw.rb:#{line}:in 'remove_tree'" }

		assert_equal formatter(StringIO.new).user_backtrace(frames), frames.first(Quickdraw::Reporters::Formatting::QUICKDRAW_FRAMES)
		assert formatter(StringIO.new).raised_in_quickdraw?(frames)
		refute formatter(StringIO.new).raised_in_quickdraw?([])
	end
end
