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
		if m_series?
			`sysctl -n hw.perflevel1.logicalcpu`.to_i
		else
			0
		end
	end

	def performance_cores
		if m_series?
			`sysctl -n hw.perflevel0.logicalcpu`.to_i
		else
			0
		end
	end

	def supports_forking?
		Process.respond_to?(:fork)
	end

	def m_series?
		mac_platform? && `sysctl -n machdep.cpu.brand_string`.include?("Apple M")
	end

	def mac_platform?
		RUBY_PLATFORM =~ /darwin/
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

	def yjit_supported?
		Kernel.const_defined?("RubyVM::YJIT") && RubyVM::YJIT.respond_to?(:enable)
	end
end
