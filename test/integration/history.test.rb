# frozen_string_literal: true

require_relative "../support/integration"

class HistoryTest < Quickdraw::Test
	include Integration

	test "--failed runs failing tests until they pass, even after a narrower run", timeout: 30 do
		skip "Run history needs sqlite3" unless bundled?("sqlite3")

		project = project(
			"a.test.rb" => <<~RUBY,
				class A < Quickdraw::Test
					test("passes") { assert true }
					test("fails until fixed") { assert ENV["QUICKDRAW_FIXTURE_FIXED"] }
				end
			RUBY
			"b.test.rb" => <<~RUBY,
				class B < Quickdraw::Test
					test("fails until fixed") { assert ENV["QUICKDRAW_FIXTURE_FIXED"] }
				end
			RUBY
		)

		match { project.run("-p", "2") => { summary: /\A3 tests · 3 assertions · 2 failed/ } }
		match { project.run("-p", "2", "--failed") => { summary: /\A2 tests · 2 assertions · 2 failed/ } }

		# Fixing only a.test.rb's failure leaves b.test.rb's for the next --failed.
		match { project.run("-p", "2", "--failed", "a.test.rb", env: { "QUICKDRAW_FIXTURE_FIXED" => "1" }) => { summary: /\A1 test · 1 assertion · / } }
		match { project.run("-p", "2", "--failed") => { summary: /\A1 test · 1 assertion · 1 failed/ } }

		project.run("-p", "2", "--failed", env: { "QUICKDRAW_FIXTURE_FIXED" => "1" })
		assert_includes project.run("-p", "2", "--failed").output, "No tests are failing in the run history."
	end

	test "--failed reruns files that failed to load", timeout: 30 do
		skip "Run history needs sqlite3" unless bundled?("sqlite3")

		project = project("broken.test.rb" => "raise 'broken'\n")

		project.run("-p", "1")
		result = project.run("-p", "1", "--failed")

		refute result.success?
		assert_includes result.output, "broken.test.rb could not be loaded"
	end

	test "rebuilds a corrupt history and keeps going", timeout: 30 do
		skip "Run history needs sqlite3" unless bundled?("sqlite3")

		project = project(
			"a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n",
			".quickdraw/history.sqlite3" => "not a database",
		)

		result = project.run("-p", "1")

		assert(result.success?) { result.output }
		refute_includes result.output, "couldn’t"
	end

	test "what reads a run's output through a pipe doesn't wait for its history to be written", timeout: 30 do
		skip "Another process writes run history only with fork" unless Process.respond_to?(:fork)

		path = File.join(tmpdir, "history.sqlite3")
		# Held, so the history process is still waiting to write once the run has gone.
		lock = Quickdraw::History.lock_for_writing(path)
		script = <<~RUBY
			require "quickdraw"
			history = Quickdraw::HistoryProcess.new(ARGV.fetch(0))
			# As #save asks, without waiting for the lock.
			history.instance_variable_get(:@channel).write([:save, { records: [] }, nil])
			puts history.instance_variable_get(:@pid)
			$stdout.flush
			exit!(0)
		RUBY

		reader, writer = IO.pipe
		run = Process.spawn(RbConfig.ruby, "-I", Quickdraw::LIB, "-e", script, path, out: writer, err: writer)
		writer.close
		Process.wait(run)
		output = +""

		closed = loop do
			break false unless reader.wait_readable(5)

			chunk = reader.read_nonblock(4096, exception: false) or break true
			output << chunk
		end

		assert(closed) { "The history process held the run's output open." }

		history = Integer(output)
		assert_equal Process.kill(0, history), 1
	ensure
		Process.kill("KILL", history) if history
		reader&.close
		lock&.close
	end

	test "the next run says when a run's history couldn't be written", timeout: 30 do
		skip "Run history needs sqlite3" unless bundled?("sqlite3")
		skip "Another process writes run history only with fork" unless Process.respond_to?(:fork)

		# A directory where the plan goes, so writing it fails once the run has ended.
		project = project(
			"a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n",
			".quickdraw/plan/file" => "",
		)

		refute_includes project.run("-p", "1").stderr, "couldn’t save"
		Quickdraw::History.wait_for_writer(File.join(project.directory, ".quickdraw/history.sqlite3"))

		File.delete(File.join(project.directory, ".quickdraw/plan/file"))
		Dir.rmdir(File.join(project.directory, ".quickdraw/plan"))
		assert_includes project.run("-p", "1").stderr, "Quickdraw couldn’t save an earlier run to its history ("
		refute_includes project.run("-p", "1").stderr, "couldn’t save"
	end

	test "a history process with no stderr leaves why it failed for the next run", timeout: 30 do
		skip "Run history needs sqlite3" unless bundled?("sqlite3")
		skip "Another process writes run history only with fork" unless Process.respond_to?(:fork)

		path = File.join(tmpdir, "history.sqlite3")
		script = <<~RUBY
			require "quickdraw"
			history = Quickdraw::HistoryProcess.new(ARGV.fetch(0))
			# Not a run, so recording it raises.
			history.save({}, nil)
			exit!(0)
		RUBY

		assert system(RbConfig.ruby, "-I", Quickdraw::LIB, "-e", script, path, err: :close)
		Quickdraw::History.wait_for_writer(path)

		assert_match Quickdraw::History.take_failure(path), /\AArgumentError: missing keyword/
		assert_equal Quickdraw::History.take_failure(path), nil
	end

	test "the run says when its history can't be locked for writing", timeout: 30 do
		skip "Another process writes run history only with fork" unless Process.respond_to?(:fork)

		path = File.join(tmpdir, "history.sqlite3")
		Dir.mkdir("#{path}.lock")
		history = Quickdraw::HistoryProcess.new(path)

		assert_raises(Quickdraw::History::Error) { history.save({ records: [] }, nil) }
	ensure
		# Until it has exited.
		history&.close&.join
	end

	test "estimates the worker count, then tunes it from history", timeout: 30 do
		skip "Choosing the worker count needs fork" unless Process.respond_to?(:fork)

		project = project("a.test.rb" => "class A < Quickdraw::Test; 10.times { |i| test(i.to_s) { assert true } }; end\n")

		assert_includes project.run("--timings").output, "(estimated)"
		assert_match project.run("--timings").output, /Workers  \d+ \((tuned|exploring)\)/
		assert_includes project.run("-p", "2", "--timings").output, "Workers  2 (manual)"
	end
end
