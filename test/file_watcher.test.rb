# frozen_string_literal: true

require "fileutils"

class FileWatcherTest < Quickdraw::Test
	# Starts the watcher on `directory`, and returns it and its warnings.
	def start(directory, ignored: [], poll: false)
		watcher = Quickdraw::Watch.start_file_watcher(ignored, directory:, poll:)

		defer do
			Process.kill("TERM", watcher.pid)
			watcher.close
		end

		lines = [watcher.gets]
		lines << watcher.gets until lines.last in "ready\n" | nil
		assert_equal lines.last, "ready\n"
		[watcher, lines[...-1].map(&:chomp)]
	end

	# Does what the block does, then returns the paths changed, once `expected`
	# have been or `within` seconds have passed.
	def changes(watcher, expected, within: 3)
		yield
		deadline = now + within
		changed = []

		until expected.difference(changed).empty? || (remaining = deadline - now) <= 0
			changed.concat(watcher.gets.chomp.split("\0")) if watcher.wait_readable(remaining)
		end

		changed.uniq.sort
	end

	def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

	def write(directory, path, content = "")
		path = File.join(directory, path)
		FileUtils.mkdir_p(File.dirname(path))
		File.write(path, content, mode: "a")
	end

	{ "from the OS" => false, "by polling" => true }.each do |how, poll|
		test "reports files created, changed, renamed and deleted, #{how}", timeout: 20 do
			directory = tmpdir
			watcher, = start(directory, poll:)

			assert_equal changes(watcher, ["a.rb"]) { write(directory, "a.rb", "1") }, ["a.rb"]
			assert_equal changes(watcher, ["a.rb"]) { write(directory, "a.rb", "2") }, ["a.rb"]
			assert_equal changes(watcher, ["a.rb", "b.rb"]) { File.rename(File.join(directory, "a.rb"), File.join(directory, "b.rb")) }, ["a.rb", "b.rb"]
			assert_equal changes(watcher, ["b.rb"]) { File.delete(File.join(directory, "b.rb")) }, ["b.rb"]
		end

		test "reports files in directories, including new and renamed ones, #{how}", timeout: 20 do
			directory = tmpdir
			write(directory, "test/models/a.test.rb")
			watcher, warnings = start(directory, poll:)

			assert_equal changes(watcher, ["test/models/a.test.rb"]) { write(directory, "test/models/a.test.rb", "1") }, ["test/models/a.test.rb"]
			assert_equal changes(watcher, ["lib/a.rb"]) { write(directory, "lib/a.rb") }, ["lib/a.rb"]
			assert_equal changes(watcher, ["lib/b.rb"]) { write(directory, "lib/b.rb") }, ["lib/b.rb"]

			# Native events name only the directory moved away, not the files that were in it.
			renamed = warnings.any? ? ["lib/a.rb", "lib/b.rb", "src/a.rb", "src/b.rb"] : ["lib", "src/a.rb", "src/b.rb"]
			assert_equal changes(watcher, renamed) { File.rename(File.join(directory, "lib"), File.join(directory, "src")) }, renamed
			assert_equal changes(watcher, ["src/c.rb"]) { write(directory, "src/c.rb") }, ["src/c.rb"]
		end

		test "ignores Quickdraw's own files, big directories and the paths it's given, #{how}", timeout: 20 do
			directory = tmpdir
			write(directory, "node_modules/a.js")
			watcher, = start(directory, ignored: ["report.xml"], poll:)

			changed = changes(watcher, ["a.rb", "lib/tmp/a.rb"]) do
				[".quickdraw/history.sqlite3", ".git/HEAD", "node_modules/a.js", "app/node_modules/a.js", "tmp/a.rb", "log/test.log", "vendor/a.rb", "coverage/index.html", "report.xml"].each do |path|
					write(directory, path)
				end

				write(directory, "lib/tmp/a.rb")
				write(directory, "a.rb")
			end

			assert_equal changed, ["a.rb", "lib/tmp/a.rb"]
		end
	end

	# Not when polling, since a scan can come in the middle of a burst.
	test "reports a burst of changes in one batch", timeout: 20 do
		directory = tmpdir
		watcher, warnings = start(directory)
		skip("The OS gives no file events.") if warnings.any?

		paths = Array.new(10) { |index| "#{index}.rb" }
		paths.each { |path| write(directory, path) }

		assert watcher.wait_readable(3)
		assert_equal watcher.gets.chomp.split("\0").sort, paths
	end

	test "starts without warnings where the OS gives file events", timeout: 20 do
		skip unless RUBY_ENGINE == "ruby" && RUBY_PLATFORM.match?(/darwin|linux/)

		_, warnings = start(tmpdir)

		assert_equal warnings, []
	end

	test "says why it polls", timeout: 20 do
		_, warnings = start(tmpdir, poll: true)

		assert_equal warnings, ["Polling for changes every 0.5s, since QUICKDRAW_POLL is set."]
	end
end
