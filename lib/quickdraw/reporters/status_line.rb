# frozen_string_literal: true

# The human reporter's line under its file lines while a run goes: a spinner,
# then how far the run has got. Everything else is printed #above it. When not
# live there's no line, and what's printed above it is only held while a
# debugger has the terminal.
class Quickdraw::Reporters::StatusLine
	include Quickdraw::Reporters::Formatting

	SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
	# Seconds between the spinner's frames.
	SPIN_INTERVAL = 0.08

	# How many test files the run will load, or nil while booting.
	attr_writer :files

	def initialize(io:, live:, color:)
		@io = io
		@live = live && io.tty? && ENV["TERM"] != "dumb"
		@color = color
		# Held while writing, so the spinner's thread doesn't write in between.
		@lock = Mutex.new
		@files = nil
		@files_done = 0
		@tests_done = 0
		@failing = 0
		@flaky = 0
		# What's printed while a debugger has the terminal, until it's done.
		@held = []
	end

	def start
		return unless @live

		@started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
		@frame = 0
		@width = terminal_width
		@ticks = Thread::Queue.new
		hide_cursor
		# Not in loaders and workers, which inherit it as they fork.
		pid = Process.pid
		at_exit { show_cursor if Process.pid == pid }

		@spinner = Thread.new do
			until @ticks.pop(timeout: SPIN_INTERVAL)
				@lock.synchronize do
					@frame += 1
					draw
				end
			end
		end
	end

	def test_passed
		@tests_done += 1
	end

	def test_done(status)
		@tests_done += 1

		case status
		in "failed" | "errored" then @failing += 1
		in "flaky" | "quarantined" then @flaky += 1
		in "skipped" | "pending" | "passed" then nil
		end
	end

	def file_done
		@files_done += 1
	end

	def redraw
		@lock.synchronize { draw }
	end

	# Now, above the status line, or once a debugger is done with the terminal.
	def above(&print)
		@lock.synchronize do
			next @held << print if @paused

			clear
			print.call
			draw
			@io.flush
		end
	end

	# While a test is in a debugger, which has the terminal, until #resume.
	def pause
		@lock.synchronize do
			clear
			show_cursor
			@paused = true
		end
	end

	def resume
		@lock.synchronize do
			@paused = false
			held, @held = @held, []
			held.each(&:call)
			hide_cursor if @spinner
			draw
			@io.flush
		end
	end

	def stop
		# Held if Ctrl-C came as a debugger was given the terminal.
		resume if @paused
		return unless @spinner

		@ticks.push(:stop)
		@spinner.join
		@spinner = nil

		@lock.synchronize do
			clear
			show_cursor
		end

		@io.flush
	end

	# The spinner, then how far the run has got. Shortened to fit the terminal,
	# since a line that wraps can't be cleared. The cursor goes back to the
	# start of the line, so what config or a loader prints writes over it.
	private def draw
		return unless @spinner && !@paused

		elapsed = format("%.1fs", Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at)
		progress = @files ? ["#{@files_done}/#{@files} files", pluralize(@tests_done, "test")] : ["Booting"]
		problems = [(red("#{@failing} failed") if @failing > 0), (yellow("#{@flaky} flaky") if @flaky > 0)].compact
		parts = [*progress, *problems, dim(elapsed)]
		room = @width - 3
		parts.delete_at(1) while parts.size > 2 && plain(parts.join(" · ")).size > room
		parts = [] if plain(parts.join(" · ")).size > room
		@io.print "\r\e[K#{[cyan(SPINNER[@frame % SPINNER.size]), (parts.join(dim(' · ')) if parts.any?)].compact.join(' ')}\r"
		@shown = true
	end

	private def clear
		return unless @shown

		@io.print "\r\e[K"
		@shown = false
	end

	# The cursor sits at the start of the status line, so it would cover the spinner.
	private def hide_cursor
		@io.print "\e[?25l"
		@cursor_hidden = true
	end

	private def show_cursor
		return unless @cursor_hidden

		@io.print "\e[?25h"
		@io.flush
		@cursor_hidden = false
	end

	private def terminal_width
		Quickdraw::Platform.terminal_columns(@io) || 80
	end

	private def red(text) = style(text, 31)
	private def yellow(text) = style(text, 33)
	private def cyan(text) = style(text, 36)
	private def dim(text) = style(text, 2)

	private def style(text, code)
		@color ? "\e[#{code}m#{text}\e[0m" : text
	end
end
