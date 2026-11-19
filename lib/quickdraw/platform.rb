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

	def yjit_supported?
		Kernel.const_defined?("RubyVM::YJIT") && RubyVM::YJIT.respond_to?(:enable)
	end
end
