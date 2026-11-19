# frozen_string_literal: true

class Quickdraw::Timer::Duration
	def initialize(nanoseconds)
		@nanoseconds = Float(nanoseconds)
	end

	attr_reader :nanoseconds

	def to_s
		if @nanoseconds < 1_000
			"#{format('%.0f', @nanoseconds)}ns"
		elsif @nanoseconds < 1_000_000
			"#{format('%.1f', @nanoseconds / 1_000)}μs"
		elsif @nanoseconds < 1_000_000_000
			"#{format('%.1f', @nanoseconds / 1_000_000)}ms"
		elsif @nanoseconds < 60_000_000_000
			"#{format('%.1f', @nanoseconds / 1_000_000_000)}s"
		else
			minutes, seconds = (@nanoseconds / 1_000_000_000).round.divmod(60)
			"#{minutes}m #{seconds}s"
		end
	end
end
