# frozen_string_literal: true

# Keeps the agent report of each run that records history, so an agent that
# didn't see the run can read it with `quickdraw last`. It's written to a
# temporary file and moved into place when the run finishes, so it's never
# part of one run.
class Quickdraw::Reporters::LastRun
	PATH = ".quickdraw/last-run.txt"

	# `command` is how the run was started, for the report's first line.
	def initialize(command:, path: PATH)
		@command = command
		@path = path
	end

	def start(**)
		require "fileutils"
		FileUtils.mkdir_p(File.dirname(@path))
		@file = File.open(temporary_path, "w")
		@file.puts "Ran `#{@command}`"
		@agent = Quickdraw::Reporters::Agent.new(io: @file)
		@agent.start(**)
	rescue SystemCallError => error
		warn "Quickdraw couldn’t write #{@path} (#{error.message})."
	end

	def result(...) = @agent&.result(...)
	def load_failed(...) = @agent&.load_failed(...)
	def finished_file(_path) = nil
	def shows_loading_output? = false
	def pause = nil
	def resume = nil

	def finish(outcome)
		return unless @agent

		@agent.finish(outcome)
		@file.close
		File.rename(temporary_path, @path)
	rescue SystemCallError => error
		warn "Quickdraw couldn’t write #{@path} (#{error.message})."
	end

	private def temporary_path = "#{@path}.#{Process.pid}"
end
