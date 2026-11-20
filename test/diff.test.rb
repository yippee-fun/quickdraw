# frozen_string_literal: true

class DiffTest < Quickdraw::Test
	# diff(old, new) returns:
	# - lines with "-" for content removed (was in old, not in new)
	# - lines with "+" for content added (in new, not in old)
	# - lines with "  " for unchanged content

	test "identical strings produce empty diff" do
		diff = Quickdraw::Diff.diff("hello", "hello")
		assert_equal diff, ""
	end

	test "completely different single lines" do
		diff = Quickdraw::Diff.diff("hello", "world")
		assert_includes diff, "- hello"
		assert_includes diff, "+ world"
	end

	test "addition at end" do
		old_text = "line1\nline2"
		new_text = "line1\nline2\nline3"

		diff = Quickdraw::Diff.diff(old_text, new_text)
		assert_includes diff, "+ line3"
		assert_includes diff, "  line1"
		assert_includes diff, "  line2"
	end

	test "deletion at end" do
		old_text = "line1\nline2\nline3"
		new_text = "line1\nline2"

		diff = Quickdraw::Diff.diff(old_text, new_text)
		assert_includes diff, "- line3"
		assert_includes diff, "  line1"
		assert_includes diff, "  line2"
	end

	test "change in middle" do
		old_text = "line1\nold_middle\nline3"
		new_text = "line1\nnew_middle\nline3"

		diff = Quickdraw::Diff.diff(old_text, new_text)
		assert_includes diff, "- old_middle"
		assert_includes diff, "+ new_middle"
		assert_includes diff, "  line1"
		assert_includes diff, "  line3"
	end

	test "empty old string" do
		diff = Quickdraw::Diff.diff("", "new content")
		assert_includes diff, "+ new content"
	end

	test "empty new string" do
		diff = Quickdraw::Diff.diff("old content", "")
		assert_includes diff, "- old content"
	end

	test "both empty strings" do
		diff = Quickdraw::Diff.diff("", "")
		assert_equal diff, ""
	end

	test "multiline with unique anchors" do
		old_text = <<~OLD
			def foo
			  old_code
			end

			def bar
			  bar_code
			end
		OLD

		new_text = <<~NEW
			def foo
			  new_code
			end

			def bar
			  bar_code
			end
		NEW

		diff = Quickdraw::Diff.diff(old_text, new_text)
		assert_includes diff, "-   old_code"
		assert_includes diff, "+   new_code"
		# Unique lines like "def foo" and "def bar" should be anchors
		assert_includes diff, "  def foo"
		assert_includes diff, "  def bar"
	end

	test "insertion between lines" do
		old_text = "first\nlast"
		new_text = "first\nmiddle\nlast"

		diff = Quickdraw::Diff.diff(old_text, new_text)
		assert_includes diff, "+ middle"
		assert_includes diff, "  first"
		assert_includes diff, "  last"
	end

	test "multiple changes" do
		old_text = "a\nb\nc\nd"
		new_text = "a\nx\nc\ny"

		diff = Quickdraw::Diff.diff(old_text, new_text)
		assert_includes diff, "- b"
		assert_includes diff, "+ x"
		assert_includes diff, "- d"
		assert_includes diff, "+ y"
		assert_includes diff, "  a"
		assert_includes diff, "  c"
	end

	test "works with inspect output for objects" do
		old_hash = { a: 1, b: 2 }
		new_hash = { a: 1, b: 3 }

		diff = Quickdraw::Diff.diff(old_hash.inspect, new_hash.inspect)
		# Should show the difference
		refute_equal diff, ""
	end

	test "handles duplicate lines with change" do
		old_text = "x\nx\nx"
		new_text = "x\ny\nx"

		diff = Quickdraw::Diff.diff(old_text, new_text)
		# Middle x changed to y
		assert_includes diff, "- x"
		assert_includes diff, "+ y"
	end

	test "matches each line at most once" do
		diff = Quickdraw::Diff.diff("0\n1\n2", "0\n0\n1\n3").gsub(/\e\[[\d;]*m/, "")

		assert_equal diff, "  0\n+ 0\n  1\n- 2\n+ 3"
	end

	test "stays fast with many repeated lines" do
		old_text = "0\n" * 10_000
		started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
		diff = Quickdraw::Diff.diff("#{old_text}1", "#{old_text}2").gsub(/\e\[[\d;]*m/, "")

		assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
		assert diff.end_with?("  0\n- 1\n+ 2")
	end

	test "finds where a text comes closest to a needle it doesn't include" do
		text = "#{(1..40).map { |i| "line #{i}" }.join("\n")}\nERROR: but nothing matches it\nFAILED"

		assert_equal Quickdraw::Diff.closest(text, "but nothing matched it"), Quickdraw::Diff::Location.new(start: text.index("but nothing matches"), line: 41, column: 8)
	end

	test "aligns the closest match a character at a time" do
		assert_equal Quickdraw::Diff.closest("xxxxx abcdXfgh xxxxx", "abcdefgh").start, 6
		assert_equal Quickdraw::Diff.closest("ab", "abc").start, 0
	end

	test "finds the closest match in text that isn't ASCII" do
		text = "#{'é' * 300}naïve café#{'ü' * 300}"

		assert_equal Quickdraw::Diff.closest(text, "naive café").start, 300
	end

	test "finds a short needle with a typo that breaks every trigram" do
		assert_equal Quickdraw::Diff.closest("#{'.' * 300}ERROR", "ERXOR").start, 300
	end

	test "finds nothing close in a text that shares nothing with the needle" do
		assert_nil Quickdraw::Diff.closest("a" * 500, "xyz")
		assert_nil Quickdraw::Diff.closest("abc", "")
	end

	test "finds the closest match in a long text quickly" do
		text = "#{'lorem ipsum dolor ' * 20_000}the needle is here"
		started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

		assert_equal Quickdraw::Diff.closest(text, "the needle was here").start, text.index("the needle")
		assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
	end

	test "preserves order of changes" do
		old_text = "1\n2\n3"
		new_text = "1\ntwo\n3"

		diff = Quickdraw::Diff.diff(old_text, new_text)
		# The deletion should come before the insertion in output
		delete_pos = diff.index("- 2")
		insert_pos = diff.index("+ two")
		refute_equal delete_pos, nil
		refute_equal insert_pos, nil
		assert_operator delete_pos, :<, insert_pos
	end
end
