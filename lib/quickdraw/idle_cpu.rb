# frozen_string_literal: true

# The share of the machine's CPU time that's idle, for Elastic: on Linux,
# from /proc/stat between readings; on macOS, from `iostat`, which prints it
# once a second. Elsewhere it's unknown, so #start returns nil.
module Quickdraw::IdleCPU
	def self.start
		if File.readable?("/proc/stat")
			ProcStat.new
		elsif Quickdraw::Platform.mac_platform?
			IOStat.new
		end
	rescue SystemCallError
		nil
	end

	class ProcStat
		# Too few ticks to tell, at 100 a second per CPU.
		MINIMUM_TICKS = 20

		def initialize
			reset
		end

		# Readings start again from now.
		def reset
			@last = read
		end

		# Since the last reading, or nil if too little time has passed.
		def sample
			current = read
			total = current.sum - @last.sum
			return if total < MINIMUM_TICKS

			# user nice system idle iowait …
			idle = current[3] + current[4] - @last[3] - @last[4]
			@last = current
			idle.fdiv(total)
		end

		def stop = nil

		private def read
			File.open("/proc/stat", &:gets).split.drop(1).first(8).map { |ticks| Integer(ticks, 10) }
		end
	end

	class IOStat
		def initialize
			# It exits from SIGPIPE within a second if this process dies without stopping it.
			@io = IO.popen(["iostat", "-n", "0", "-w", "1"], in: File::NULL, err: File::NULL)
			@buffer = +""
			reset
		end

		# Only seconds mostly after now count. Lines are read up to a quarter
		# of a second after iostat prints them (see Elastic::INTERVAL), so a
		# second that counts can start up to half a second before now.
		def reset
			take_lines
			@after = now + 0.75
		end

		# The latest second's, or nil if no second has ended since the last.
		def sample
			lines = take_lines
			return if now < @after

			lines.filter_map { |line| idle(line) }.last
		end

		def stop
			Process.kill("TERM", @io.pid)
		rescue Errno::ESRCH
			nil
		ensure
			@io.close
		end

		# Lines are "us sy id 1m 5m 15m", under headers.
		private def idle(line)
			percent = line.split[2]
			Integer(percent, 10, exception: false)&.fdiv(100) if percent
		end

		private def take_lines
			loop do
				chunk = @io.read_nonblock(4096, exception: false)
				break unless String === chunk

				@buffer << chunk
			end

			*lines, rest = @buffer.split("\n", -1)
			@buffer = +(rest || "")
			lines
		end

		private def now
			Process.clock_gettime(Process::CLOCK_MONOTONIC)
		end
	end
end
