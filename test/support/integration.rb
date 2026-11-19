# frozen_string_literal: true

# Runs Quickdraw in a separate process against a throwaway project, for testing
# the runner itself. Core Ruby only, so it can't hide a missing require in the
# library.
module Integration
	ROOT = File.expand_path("../..", __dir__)
	EXECUTABLE = File.join(ROOT, "exe", "quickdraw")

	# `summary` is the "N tests · …" line. It's a member, rather than a method,
	# so pattern matching can use it.
	Result = Data.define(:output, :summary, :status, :duration) do
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
			reader, writer = IO.pipe

			pid = Process.spawn(
				# Unset what Quickdraw sets in this test's own worker, or the user's shell.
				{ "NO_COLOR" => "1", "SEED" => nil, "QUICKDRAW_WORKER" => nil, "TEST_ENV_NUMBER" => nil, **env },
				RbConfig.ruby, "-I", File.join(ROOT, "lib"), EXECUTABLE, *,
				chdir: @directory,
				out: writer,
				err: writer,
				pgroup: true,
			)

			writer.close
			output = +""
			started_at = now
			status = nil

			until status
				if now - started_at > timeout
					kill_group(pid)
					Process.wait(pid)
					raise "Quickdraw didn’t finish within #{timeout}s. Output so far:\n#{output}"
				end

				reader.wait_readable(0.05)
				drain(reader, output)
				_, status = Process.wait2(pid, Process::WNOHANG)
			end

			drain(reader, output)
			kill_group(pid)
			output.force_encoding(Encoding::UTF_8)

			Result.new(output:, summary: output[/^\d+ tests? ·.*$/], status:, duration: now - started_at)
		ensure
			reader&.close
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
