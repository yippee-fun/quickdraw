# frozen_string_literal: true

require_relative "../support/integration"

class HistoryCommandTest < Quickdraw::Test
	include Integration

	test "says there's no history yet, without creating one" do
		project = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n")

		result = project.run("history")

		assert_equal result.status.exitstatus, 1
		assert_includes result.stdout, "No run history yet."
		refute File.exist?(File.join(project.directory, ".quickdraw"))
	end

	test "rejects arguments" do
		result = project.run("history", "--slowest")

		assert_equal result.status.exitstatus, 2
		assert_match result.stderr, /\AUsage: .*quickdraw history\n\z/
	end

	test "reports a history it can't read" do
		project = project(".quickdraw/history.sqlite3/.keep" => "")

		result = project.run("history")

		assert_equal result.status.exitstatus, 1
		assert_includes result.stderr, "Couldn’t read the run history"
	end

	test "leaves a history from another version of Quickdraw alone", timeout: 30 do
		require "sqlite3"
		project = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n")
		project.run("-p", "1")
		path = File.join(project.directory, ".quickdraw/history.sqlite3")
		SQLite3::Database.new(path) { |database| database.execute("PRAGMA user_version = 1") }

		result = project.run("history")

		assert_equal result.status.exitstatus, 1
		assert_includes result.stderr, "recorded by a different version of Quickdraw"
		database = SQLite3::Database.new(path)
		defer { database.close }
		assert_equal database.get_first_value("SELECT count(*) FROM runs"), 1
	end

	test "lists recent runs and the slowest tests", timeout: 30 do
		project = project(
			"a.test.rb" => <<~RUBY,
				class A < Quickdraw::Test
					test("fast") { assert true }
					test("slow") { sleep 0.05; assert true }
				end
			RUBY
		)

		project.run("-p", "1")
		project.run("-p", "2")
		result = project.run("history")

		assert(result.success?) { result.output }
		assert_includes result.stdout, "Recent runs"
		assert_match result.stdout, /✓ +\d+s ago  2 tests · .* · 2 workers \(manual\) · seed \d+\n  ✓ +\d+s ago  2 tests · .* · 1 worker \(manual\)/
		assert_match result.stdout, /Slowest tests\n +\S+  a\.test\.rb:3 A › slow\n +\S+  a\.test\.rb:2 A › fast\n/
		refute_includes result.stdout, "Flaky tests"
	end

	test "lists tests that passed and failed on the same code as flaky", timeout: 30 do
		project = project(
			"a.test.rb" => <<~RUBY,
				class A < Quickdraw::Test
					test("stable") { assert true }
					test("flaky") { refute ENV["QUICKDRAW_FIXTURE_FAIL"] }
				end
			RUBY
		)

		project.run("-p", "1")
		project.run("-p", "1", env: { "QUICKDRAW_FIXTURE_FAIL" => "1" })
		project.run("-p", "1")
		result = project.run("history")

		assert(result.success?) { result.output }
		assert_match result.stdout, /✗ +\d+s ago  2 tests · 1 failed · /
		assert_match result.stdout, /Flaky tests.*\n  failed 1 of 3  a\.test\.rb:3 A › flaky\n\z/
	end

	test "doesn't count a test that failed on one commit and passed on the next as flaky", timeout: 30 do
		project = project(
			"a.test.rb" => <<~RUBY,
				class A < Quickdraw::Test
					test("fixed") { refute ENV["QUICKDRAW_FIXTURE_FAIL"] }
				end
			RUBY
		)

		git(project, "init", "--quiet")
		git(project, "commit", "--quiet", "--allow-empty", "--no-verify", "-m", "Break")
		project.run("-p", "1", env: { "QUICKDRAW_FIXTURE_FAIL" => "1" })
		git(project, "commit", "--quiet", "--allow-empty", "--no-verify", "-m", "Fix")
		project.run("-p", "1")
		result = project.run("history")

		assert(result.success?) { result.output }
		assert_match result.stdout, /✓ +\d+s ago  1 test · .* · \h{7} \S+\n  ✗ +\d+s ago  1 test · 1 failed · .* · \h{7} \S+\n/
		refute_includes result.stdout, "Flaky tests"
	end

	test "doesn't count a test that failed, then passed after an uncommitted change, as flaky", timeout: 30 do
		test_file = <<~RUBY
			class A < Quickdraw::Test
				test("fixed") { refute ENV["QUICKDRAW_FIXTURE_FAIL"] }
			end
		RUBY
		project = project("a.test.rb" => test_file)

		git(project, "init", "--quiet")
		git(project, "add", "a.test.rb")
		git(project, "commit", "--quiet", "--no-verify", "-m", "Add a test")
		project.run("-p", "1", env: { "QUICKDRAW_FIXTURE_FAIL" => "1" })
		project.write("a.test.rb" => "#{test_file}# Fixed\n")
		project.run("-p", "1")
		project.run("-p", "1")

		refute_includes project.run("history").stdout, "Flaky tests"

		# The same uncommitted code, passing and failing, is flaky.
		project.run("-p", "1", env: { "QUICKDRAW_FIXTURE_FAIL" => "1" })
		assert_includes project.run("history").stdout, "failed 1 of 3  a.test.rb:2 A › fixed"
	end

	private def git(project, *)
		system("git", "-C", project.directory, "-c", "user.name=Quickdraw", "-c", "user.email=quickdraw@example.com", "-c", "commit.gpgsign=false", *, exception: true)
	end
end
