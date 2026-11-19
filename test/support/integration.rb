# frozen_string_literal: true

# Runs Quickdraw in a separate process against a throwaway project, for testing
# the runner itself. Core Ruby only, so it can't hide a missing require in the
# library.
module Integration
	ROOT = File.expand_path("../..", __dir__)
	EXECUTABLE = File.join(ROOT, "exe", "quickdraw")

	# `output` is stdout then stderr. `summary` is the "N tests · …" line. They're
	# members, rather than methods, so pattern matching can use them.
	Result = Data.define(:stdout, :stderr, :output, :summary, :status, :duration) do
		def success? = status.success?
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
		# close, since processes a test forks can hold the output open.
		def run(*, env: {}, timeout: 10)
			stdout_reader, stdout_writer = IO.pipe
			stderr_reader, stderr_writer = IO.pipe

			pid = Process.spawn(
				# Unset what Quickdraw sets in this test's own worker, or the environment
				# this suite runs in (an AI agent, GitHub Actions, an option parser
				# setting), so behaviour is only what the test asks for.
				{
					"NO_COLOR" => "1",
					"SEED" => nil,
					"QUICKDRAW_WORKER" => nil,
					"TEST_ENV_NUMBER" => nil,
					"GITHUB_ACTIONS" => nil,
					"GITHUB_STEP_SUMMARY" => nil,
					"POSIXLY_CORRECT" => nil,
					**Quickdraw::Reporters::AGENT_VARIABLES.to_h { |name| [name, nil] },
					**env,
				},
				RbConfig.ruby, "-I", File.join(ROOT, "lib"), EXECUTABLE, *,
				chdir: @directory,
				out: stdout_writer,
				err: stderr_writer,
				pgroup: true,
			)

			stdout_writer.close
			stderr_writer.close
			stdout = +""
			stderr = +""
			started_at = now
			status = nil

			until status
				if now - started_at > timeout
					kill_group(pid)
					Process.wait(pid)
					raise "Quickdraw didn’t finish within #{timeout}s. Output so far:\n#{stdout}#{stderr}"
				end

				IO.select([stdout_reader, stderr_reader], nil, nil, 0.05)
				drain(stdout_reader, stdout)
				drain(stderr_reader, stderr)
				_, status = Process.wait2(pid, Process::WNOHANG)
			end

			drain(stdout_reader, stdout)
			drain(stderr_reader, stderr)
			kill_group(pid)
			output = "#{stdout.force_encoding(Encoding::UTF_8)}#{stderr.force_encoding(Encoding::UTF_8)}"

			Result.new(stdout:, stderr:, output:, summary: output[/^\d+ tests? ·.*$/], status:, duration: now - started_at)
		ensure
			stdout_reader&.close
			stderr_reader&.close
		end

		private def drain(reader, output)
			loop do
				chunk = reader.read_nonblock(65_536, exception: false)
				break unless String === chunk

				output << chunk
			end
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
