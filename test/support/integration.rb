# frozen_string_literal: true

# Runs Quickdraw in a separate process against a throwaway project, for testing
# the runner itself. Core Ruby only, so it can't hide a missing require in the
# library.
module Integration
	ROOT = File.expand_path("../..", __dir__)
	EXECUTABLE = File.join(ROOT, "exe", "quickdraw")

	# `output` is stdout then stderr. `summary` is the counts from the human
	# summary's rows as one line, "N tests · N assertions · N failed · … · 0.05s",
	# so tests can match counts without depending on the layout. They're
	# members, rather than methods, so pattern matching can use them.
	Result = Data.define(:stdout, :stderr, :output, :summary, :status, :exit_status, :duration) do
		def success? = status.success?
	end

	# Each run's summary (see .summary), for watch mode's many runs.
	def self.summaries(output)
		output.delete("\r").split(/^(?= +Test files  )/).filter_map { |part| summary(part) }
	end

	# The order and wording of the counts in a Result's summary.
	SUMMARY_COUNTS = ["failed", "flaky (allowed)", "flaky", "skipped", "pending", "errored", "not run"].freeze

	# From the last summary's Tests, Test files, Assertions and Duration rows,
	# or nil. The live block uses the same labels, but has no Assertions row.
	def self.summary(output)
		# Terminals end lines with \r\n.
		output = output.delete("\r")
		start = output.rindex(/^ +Test files  /) or return
		output = output[start..]
		return unless output.match?(/^ +Assertions  /)

		tests_row = output[/^ +Tests  (.*\(\d+\))$/, 1] or return
		files_row = output[/^ +Test files  (.*)$/, 1]
		tests = Integer(tests_row[/\((\d+)\)\z/, 1])
		# Files that failed to load count as errored, as they did in one line.
		errored = tests_row[/(\d+) errored/, 1].to_i + files_row[/(\d+) failed to load/, 1].to_i

		counts = SUMMARY_COUNTS.filter_map do |name|
			count = (name == "errored") ? (errored if errored > 0) : tests_row[/(\d+) #{Regexp.escape(name)}(?= ·| \(|\z)/, 1]
			"#{count} #{name}" if count
		end

		unloaded = files_row[/(\d+) not loaded/, 1]
		without = tests_row[/(\d+) without assertions/, 1]
		assertions = Integer(output[/^ +Assertions  ([\d,]+)$/, 1].delete(","))

		[
			"#{tests} #{(tests == 1) ? 'test' : 'tests'}",
			"#{assertions} #{(assertions == 1) ? 'assertion' : 'assertions'}",
			*counts.uniq { |count| count.sub(" (allowed)", "") },
			("#{unloaded} #{(unloaded == '1') ? 'file' : 'files'} not loaded" if unloaded),
			("#{without} without assertions" if without),
			output[/^ +Duration  ([\d.]+s)/, 1],
		].compact.join(" · ")
	end

	class Project
		def initialize(directory)
			@directory = directory
		end

		attr_reader :directory

		# `files` maps paths, relative to the project, to their contents.
		def write(files)
			files.each do |path, source|
				full_path = File.join(@directory, path)
				mkdir_p(File.dirname(full_path))
				File.write(full_path, source)
			end
		end

		# Runs Quickdraw to completion, or kills it and everything it started after
		# `timeout` seconds. Waits for the process rather than for its output to
		# close, since processes a test forks can hold the output open. Once the
		# output matches `interrupt_when`, sends Ctrl-C to every process, as a
		# terminal does. With `tty: [rows, columns]`, runs on a terminal of that
		# size, which both streams go to, so everything is in stdout.
		#
		# A block is called with the output so far and the process's input about
		# every 50ms, to interact with it as a person would.
		def run(*arguments, env: {}, timeout: 10, interrupt_when: nil, tty: nil, &interact)
			# Unset what Quickdraw sets in this test's own worker, or the environment
			# this suite runs in (an AI agent, GitHub Actions, an option parser
			# setting), so behaviour is only what the test asks for.
			environment = {
				"NO_COLOR" => "1",
				"SEED" => nil,
				"QUICKDRAW_WORKER" => nil,
				"TEST_ENV_NUMBER" => nil,
				"GITHUB_ACTIONS" => nil,
				"GITHUB_STEP_SUMMARY" => nil,
				"POSIXLY_CORRECT" => nil,
				# Bundler resolves the Gemfile in every process, which takes about
				# 120ms. The load path it set up for this one does the same job.
				"RUBYOPT" => nil,
				"BUNDLE_GEMFILE" => nil,
				"BUNDLER_SETUP" => nil,
				"RUBYLIB" => $LOAD_PATH.join(File::PATH_SEPARATOR),
				**Quickdraw::Reporters::AGENT_VARIABLES.to_h { |name| [name, nil] },
				**env,
			}
			command = [RbConfig.ruby, "-I", File.join(ROOT, "lib"), EXECUTABLE, *arguments]

			pid, stdout_reader, stderr_reader, input = tty ? spawn_on_terminal(environment, command, *tty) : spawn(environment, command)
			readers = [stdout_reader, stderr_reader].compact
			stdout = +""
			stderr = +""
			started_at = now
			status = nil

			until status
				if now - started_at > timeout
					kill_group(pid)
					Process.wait(pid)
					raise "Quickdraw didn’t finish within #{timeout}s. Output so far:\n#{Quickdraw.utf8("#{stdout}#{stderr}")}"
				end

				IO.select(readers, nil, nil, 0.05)
				drain(stdout_reader, stdout)
				drain(stderr_reader, stderr)
				interact&.call(Quickdraw.utf8("#{stdout}#{stderr}"), input)

				if interrupt_when && (interrupt_when.match?(stdout) || interrupt_when.match?(stderr))
					Process.kill("INT", -pid)
					interrupt_when = nil
				end

				_, status = Process.wait2(pid, Process::WNOHANG)
			end

			drain(stdout_reader, stdout)
			drain(stderr_reader, stderr)
			kill_group(pid)
			# Run history is written after the run ends (see HistoryProcess), so
			# the project, and the next run, see it as a person would.
			Quickdraw::History.wait_for_writer(File.join(@directory, Quickdraw::CLI::HISTORY_PATH))
			output = "#{stdout.force_encoding(Encoding::UTF_8)}#{stderr.force_encoding(Encoding::UTF_8)}"

			Result.new(stdout:, stderr:, output:, summary: Integration.summary(output), status:, exit_status: status.exitstatus, duration: now - started_at)
		ensure
			stdout_reader&.close
			stderr_reader&.close
			input&.close
		end

		# Runs in watch mode with one worker, on a terminal. Each of `changes` is
		# written (as by #write) once the output shows `Watching` one more time,
		# and again, with a different comment, if no run has started (clearing
		# the screen) within a second, in case the watcher missed it. Then quits.
		def watch(*changes)
			saved_at = {}
			quit = false

			run("-p", "1", "--watch", tty: [40, 120], timeout: 30) do |output, keyboard|
				watching = output.scan(/^Watching/).size
				next if watching == 0

				if (files = changes[watching - 1])
					next if saved_at[watching] && (now - saved_at[watching] < 1 || output.scan("\e[2J").size > watching)

					write(files.transform_values { |source| "#{source}# #{now}\n" })
					saved_at[watching] = now
				elsif !quit
					keyboard.write("q")
					quit = true
				end
			end
		end

		private def spawn(environment, command)
			stdout_reader, stdout_writer = IO.pipe
			stderr_reader, stderr_writer = IO.pipe
			stdin_reader, stdin_writer = IO.pipe
			pid = Process.spawn(environment, *command, chdir: @directory, in: stdin_reader, out: stdout_writer, err: stderr_writer, pgroup: true)

			[pid, stdout_reader, stderr_reader, stdin_writer]
		ensure
			stdout_writer&.close
			stderr_writer&.close
			stdin_reader&.close
		end

		# The process leads a new session, so it has its own process group too.
		# PTY.spawn has no chdir option, hence the Ruby that changes directory.
		private def spawn_on_terminal(environment, command, rows, columns)
			require "pty"
			require "io/console"

			reader, writer, pid = PTY.spawn(environment, RbConfig.ruby, "-e", "Dir.chdir(ARGV.shift); exec(*ARGV)", @directory, *command)
			reader.winsize = [rows, columns]

			[pid, reader, nil, writer]
		end

		# A terminal raises EIO once the process has gone.
		private def drain(reader, output)
			return unless reader

			loop do
				chunk = reader.read_nonblock(65_536, exception: false)
				break unless String === chunk

				output << chunk
			end
		rescue Errno::EIO
			nil
		end

		# Anything the run left behind, such as a process a test forked.
		private def kill_group(pid)
			Process.kill("KILL", -pid)
		rescue Errno::ESRCH, Errno::EPERM
			nil
		end

		private def mkdir_p(path)
			return if Dir.exist?(path)

			mkdir_p(File.dirname(path))
			Dir.mkdir(path)
		end

		private def now
			Process.clock_gettime(Process::CLOCK_MONOTONIC)
		end
	end

	# A Project in a new temporary directory, with `files` written to it.
	def project(files = {})
		Project.new(tmpdir).tap { |project| project.write(files) }
	end
end
