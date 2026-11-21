# frozen_string_literal: true

module Quickdraw::Platform
	extend self

	# The number of CPU cores for an ideal balance of performance and user experience.
	#
	# In the case of an M-series Mac, this is all your performance cores, leaving the
	# efficienty cores for other tasks. On other platforms, this is all available CPU
	# cores, minus one.
	def non_blocking_cores
		if m_series?
			performance_cores
		elsif cpu_cores > 1
			cpu_cores - 1
		else
			cpu_cores
		end
	end

	def efficiency_cores
		m_series? ? core_levels.last : 0
	end

	def performance_cores
		m_series? ? core_levels.first : 0
	end

	def supports_forking?
		Process.respond_to?(:fork)
	end

	# Every arm64 Mac is Apple silicon, so this needs no subprocess.
	def m_series?
		mac_platform? && RUBY_PLATFORM.start_with?("arm64")
	end

	def mac_platform?
		RUBY_PLATFORM =~ /darwin/
	end

	CORE_LEVELS_CACHE = "~/Library/Caches/quickdraw/core-levels"

	# [performance, efficiency] logical cores. sysctl takes ~6ms to run and a
	# machine's cores don't change, so they're cached. Every core counts as a
	# performance core if sysctl can't say.
	private def core_levels
		@core_levels ||= cached_core_levels(CORE_LEVELS_CACHE) || sysctl_core_levels&.tap { |levels| cache_core_levels(CORE_LEVELS_CACHE, levels) } || [cpu_cores, 0]
	end

	private def cached_core_levels(path)
		levels, kernel = File.read(File.expand_path(path)).split("\n", 2)
		valid_core_levels(levels) if kernel == self.kernel
	rescue SystemCallError, ArgumentError
		nil
	end

	private def cache_core_levels(path, levels)
		path = File.expand_path(path)
		Dir.mkdir(File.dirname(path)) unless File.directory?(File.dirname(path))
		File.write(path, "#{levels.join(' ')}\n#{kernel}")
	rescue SystemCallError, ArgumentError
		nil
	end

	# From one sysctl, since each takes ~2ms.
	private def sysctl_core_levels
		valid_core_levels(`sysctl -n hw.perflevel0.logicalcpu hw.perflevel1.logicalcpu 2>/dev/null`)
	rescue SystemCallError
		nil
	end

	# Names the chip, as in RELEASE_ARM64_T6000, which tells apart machines
	# that split as many cores differently. uname(2) takes no subprocess.
	private def kernel
		require "etc"
		Etc.uname[:version]
	end

	# Levels that don't add up to this machine's cores are another machine's.
	private def valid_core_levels(text)
		levels = text.split.map { |count| Integer(count, 10, exception: false) }
		levels if levels.size == 2 && levels.all? { |count| count&.positive? } && levels.sum == cpu_cores
	end

	def cpu_cores
		require "etc"
		Etc.nprocessors
	end

	# The share of memory available for new processes without swapping, or nil
	# if it can't be told. On Linux, the tighter of the machine's and this
	# process's cgroup (v2) limit, as in a container.
	def available_memory
		if File.readable?("/proc/meminfo")
			info = File.foreach("/proc/meminfo").to_h { |line| name, kilobytes = line.split; [name.chomp(":"), kilobytes.to_i] }
			machine = info["MemAvailable"].fdiv(info["MemTotal"]) if info["MemAvailable"] && info["MemTotal"].to_i > 0
			limit = Integer(cgroup("memory.max") || "", 10, exception: false)
			used = Integer(cgroup("memory.current") || "", 10, exception: false)
			[machine, (1 - used.fdiv(limit) if limit && used && limit > 0)].compact.min
		elsif mac_platform?
			Integer(`sysctl -n kern.memorystatus_level`.strip, 10, exception: false)&.fdiv(100)
		end
	rescue SystemCallError
		nil
	end

	# How many CPUs a Linux cgroup (v2) quota allows this process, as in a
	# container, or nil without one.
	def cpu_quota
		quota, period = cgroup("cpu.max")&.split
		Integer(quota, 10, exception: false)&.fdiv(Integer(period, 10)) if quota && period
	rescue SystemCallError
		nil
	end

	# A setting of this process's cgroup (v2), or nil.
	private def cgroup(name)
		group = File.foreach("/proc/self/cgroup").find { |line| line.start_with?("0::") }&.chomp&.delete_prefix("0::")
		path = File.join("/sys/fs/cgroup", group.to_s, name)
		File.read(path).strip if group && File.readable?(path)
	rescue SystemCallError
		nil
	end

	# Linux's is 0x5413 except where it took its ioctl numbers from BSD.
	TIOCGWINSZ = case RUBY_PLATFORM
	in /darwin|bsd|dragonfly/ then 0x40087468
	in /linux/ then RUBY_PLATFORM.match?(/mips|powerpc|ppc|sparc|alpha/) ? 0x40087468 : 0x5413
	else nil
	end

	# How many columns wide `io`'s terminal is, or nil if it isn't one or
	# can't say. From an ioctl rather than io/console, which group loaders,
	# forked from this process, would pass on to tests, and rather than stty
	# where it can be, since running that takes ~2ms.
	def terminal_columns(io)
		return unless io.tty?

		columns = ioctl_columns(io) || stty_columns(io)
		columns if columns&.positive?
	end

	private def ioctl_columns(io)
		return unless TIOCGWINSZ

		# struct winsize: rows, columns, then width and height in pixels.
		size = [0, 0, 0, 0].pack("S!4")
		io.ioctl(TIOCGWINSZ, size)
		size.unpack("S!4")[1]
	rescue SystemCallError, NotImplementedError, ArgumentError
		nil
	end

	private def stty_columns(io)
		Integer(IO.popen(["stty", "size"], in: io, err: File::NULL, &:read).split.last, 10, exception: false)
	rescue SystemCallError
		nil
	end

	def yjit_supported?
		Kernel.const_defined?("RubyVM::YJIT") && RubyVM::YJIT.respond_to?(:enable)
	end
end
