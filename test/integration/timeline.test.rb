# frozen_string_literal: true

require_relative "../support/integration"

class TimelineTest < Quickdraw::Test
	include Integration

	def chart(project) = File.read(File.join(project.directory, ".quickdraw/timeline.html"), encoding: Encoding::UTF_8)

	test "summarises how workers spent the run and names the tests it waited for at the end", timeout: 20 do
		skip "More than one worker needs fork" unless Process.respond_to?(:fork)

		project = project(
			"slow.test.rb" => "class Slow < Quickdraw::Test; test('sleeps') { sleep 0.5; assert true }; end\n",
			"fast.test.rb" => "class Fast < Quickdraw::Test; 20.times { |i| test(\"fast \#{i}\") { assert true } }; end\n",
		)

		result = project.run("-p", "2", "--no-history", "--timeline")

		assert result.success?
		assert_includes result.stdout, "Timeline .quickdraw/timeline.html"
		assert_match result.stdout, /^  \d\.\d\ds booting · \d\.\d\ds running tests · \d\.\d\ds stopping$/
		assert_match result.stdout, /^  2 workers: \d+% running tests · .*\d+% idle at the end$/
		assert_match result.stdout, /^  For the last 0\.\d\ds, workers ran out of work while these ran:\n +0\.[5-9]\ds  slow\.test\.rb:1 Slow › sleeps$/
		# Before the result, like the other summaries.
		assert result.stdout.index("Timeline") < result.stdout.index("PASSED")
	end

	test "charts each worker slot's batches, file loads and the tests the run waited for", timeout: 20 do
		skip "More than one worker needs fork" unless Process.respond_to?(:fork)

		project = project(
			"slow.test.rb" => "class Slow < Quickdraw::Test; test('sleeps') { sleep 0.3; assert true }; end\n",
			"fast.test.rb" => "class Fast < Quickdraw::Test; 5.times { |i| test(\"fast \#{i}\") { assert true } }; end\n",
		)

		project.run("-p", "2", "--no-history", "--timeline")
		html = chart(project)

		assert_includes html, "<span class=\"label\">Worker 0</span>"
		assert_includes html, "<span class=\"label\">Worker 1</span>"
		assert_match html, /<span class="running" style="left: [\d.]+%; width: [\d.]+%" title="slow\.test\.rb:1 Slow › sleeps: \d+ms">/
		assert_match html, /<span class="loading" [^>]*title="Loading fast\.test\.rb: \d+ms">/
		assert_match html, %r{<td><code>slow\.test\.rb:1</code> Slow › sleeps</td><td>\d+ms</td>}
	end

	test "shows a test that crashed its worker running until it exited, and the worker that replaced it", timeout: 20 do
		skip "Replacing crashed workers needs fork" unless Process.respond_to?(:fork)

		project = project("crash.test.rb" => <<~RUBY)
			class Crash < Quickdraw::Test
				test("kills its worker") { sleep 0.05; exit!(1) }
				3.times { |i| test("after \#{i}") { sleep 0.05; assert true } }
			end
		RUBY

		result = project.run("-p", "1", "--no-history", "--retry", "0", "--seed", "1", "--timeline")
		html = chart(project)

		refute result.success?
		assert_match html, /class="running" [^>]*title="crash\.test\.rb:2 Crash › kills its worker: \d+ms"/
		assert_equal html.scan(/title="Starting: \d+ms"/).size, 2
	end

	test "still reports the run when the chart can't be written", timeout: 20 do
		project = project("one.test.rb" => "class One < Quickdraw::Test; test('passes') { assert true }; end\n")
		Dir.mkdir(File.join(project.directory, ".quickdraw"))
		Dir.mkdir(File.join(project.directory, ".quickdraw/timeline.html"))
		result = project.run("-p", "1", "--no-history", "--timeline")

		assert result.success?
		assert_includes result.stderr, "Quickdraw couldn’t write .quickdraw/timeline.html"
		assert_includes result.stdout, "Timeline .quickdraw/timeline.html"
	end

	test "won't let a format write where the chart goes", timeout: 20 do
		result = project("one.test.rb" => "class One < Quickdraw::Test; end\n").run("--timeline", "--format", "json:.quickdraw/timeline.html")

		assert_equal result.exit_status, 2
		assert_includes result.stderr, "--timeline writes its chart to .quickdraw/timeline.html"
	end

	test "writes nothing without --timeline", timeout: 20 do
		project = project("one.test.rb" => "class One < Quickdraw::Test; test('passes') { assert true }; end\n")
		result = project.run("-p", "1", "--no-history")

		refute_includes result.stdout, "Timeline"
		refute File.exist?(File.join(project.directory, ".quickdraw/timeline.html"))
	end

	test "goes to stderr when a format other programs read is on the terminal", timeout: 20 do
		project = project("one.test.rb" => "class One < Quickdraw::Test; test('passes') { assert true }; end\n")
		result = project.run("-p", "1", "--no-history", "--timeline", "--format", "json")

		assert_includes result.stderr, "Timeline .quickdraw/timeline.html"
		result.stdout.each_line { |line| assert line.start_with?("{") }
	end
end
