# frozen_string_literal: true

class Quickdraw::Reporter
	ANSI = /\e\[[\d;]*m/

	def initialize(io: $stdout, backtrace: false)
		@io = io
		@backtrace = backtrace
		@color = io.tty? && !ENV.key?("NO_COLOR")
		@live = io.tty?
		@problems = []
		@tests = 0
		@assertions = 0
		@failed = 0
		@errored = 0
		@without_assertions = 0
		@last_progress_at = 0.0
	end

	def start(processes:, seed:)
		@processes = processes
		@seed = seed
		@started_at = now
	end

	def result(path, test, result)
		@tests += 1
		@assertions += result["assertions"]

		if result["errors"].any?
			@errored += 1
			@problems << [path, test, result]
		elsif result["failures"].any?
			@failed += 1
			@problems << [path, test, result]
		elsif result["assertions"] == 0
			@without_assertions += 1
		end

		progress
	end

	def load_failed(path, error)
		@errored += 1
		@problems << [path, nil, { "errors" => [error], "failures" => [] }]
	end

	def finish(not_run:, processes_failed:)
		duration = now - @started_at
		@io.print "\r\e[K" if @live

		@problems.each { |problem| print_problem(*problem) }

		if processes_failed && @problems.empty?
			@io.puts
			@io.puts "#{red('✗')} A worker or the loader exited with a failure status (e.g. from an at_exit hook)."
		end

		@io.puts
		@io.puts [
			"#{@tests} tests",
			"#{@assertions} assertions",
			("#{@failed} failed" if @failed > 0),
			("#{@errored} errored" if @errored > 0),
			("#{not_run} not run" if not_run > 0),
			("#{@without_assertions} without assertions" if @without_assertions > 0),
			format("%.2fs", duration),
		].compact.join(" · ")
		@io.puts dim("Seed #{@seed} · #{@processes} workers · quickdraw --seed #{@seed}")

		@failed == 0 && @errored == 0 && not_run == 0 && !processes_failed
	end

	private def print_problem(path, test, result)
		@io.puts

		if test
			line = "#{path}:#{test['line']}"
			name = [test["class_name"], test["description"]].compact.join(" › ")
			@io.puts "#{red('✗')} #{bold(line)} #{name}"
		else
			@io.puts "#{red('✗')} #{bold(path)} could not be loaded"
		end

		result["failures"].each do |failure|
			@io.puts "  #{dim("#{relative(failure['path'])}:#{failure['line']}")}"
			@io.puts
			@io.puts indent(clean(failure["message"]), 4)
		end

		result["errors"].each do |error|
			@io.puts "  #{red(error['name'])}: #{clean(error['message'])}"
			backtrace(error["backtrace"]).each { |frame| @io.puts "    #{dim(relative(frame))}" }
		end
	end

	private def backtrace(frames)
		return frames if @backtrace

		user_frames = frames.take_while { |frame| !frame.start_with?(Quickdraw::LIB) }
		user_frames.empty? ? frames : user_frames
	end

	private def progress
		return unless @live

		time = now
		return if time - @last_progress_at < 0.05

		@last_progress_at = time
		@io.print "\r\e[K#{@tests} tests#{" · #{red("#{@failed + @errored} problems")}" if @problems.any?}"
	end

	private def indent(text, spaces)
		text.gsub(/^(?=.)/, " " * spaces)
	end

	private def relative(path)
		path.delete_prefix("#{Dir.pwd}/")
	end

	private def clean(text)
		text = text.scrub
		@color ? text : text.gsub(ANSI, "")
	end

	private def red(text) = style(text, 31)
	private def bold(text) = style(text, 1)
	private def dim(text) = style(text, 2)

	private def style(text, code)
		@color ? "\e[#{code}m#{text}\e[0m" : text
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
