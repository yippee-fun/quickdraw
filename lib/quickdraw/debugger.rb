# frozen_string_literal: true

# Lets a test stop in a debugger during a parallel run. Before the debugger
# reads from the terminal, the worker asks the coordinator for it, which gives
# it to one worker at a time and holds the reporter's output; the worker stops
# capturing output and pauses the test's timeout until the debugger is done.
#
# irb and pry return once they exit, so they hold the terminal for the call.
# The debug gem (`debugger`, `binding.break`) stops in its own thread, so it
# holds the terminal while its session is stopped.
#
# Runs in workers, so it must only use core Ruby.
module Quickdraw::Debugger
	extend self

	# A file that exists while a worker's debugger has the terminal, so other
	# processes leave Ctrl-C to it. Its path is set by the CLI for runs that
	# hand out the terminal, and inherited by every process in them.
	FLAG = "QUICKDRAW_DEBUGGING"

	module BindingMethods
		def irb(...) = Quickdraw::Debugger.holding_terminal { super }
		def pry(...) = Quickdraw::Debugger.holding_terminal { super }
	end

	# Gives the terminal back before the session lets the test carry on.
	module DebugSessionMethods
		private def enter_subsession
			@quickdraw_depth = (@quickdraw_depth || 0) + 1
			Quickdraw::Debugger.take_terminal if @quickdraw_depth == 1
			super
		end

		private def leave_subsession(...)
			@quickdraw_depth -= 1
			Quickdraw::Debugger.give_back_terminal if @quickdraw_depth == 0
			super
		end
	end

	# `worker` gets the terminal (see Worker#take_terminal) for runs that hand
	# it out.
	def install(worker)
		return unless ENV.key?(FLAG)

		@worker = worker
		@pid = Process.pid
		Binding.prepend(BindingMethods)
		hook_debug_gem
	end

	# After this, a debugger, say in an at_exit hook, just uses the terminal.
	def uninstall
		@worker = nil
	end

	def holding_terminal(&)
		worker ? worker.holding_terminal(&) : yield
	end

	def take_terminal = worker&.take_terminal(:debug_gem)
	def give_back_terminal = worker&.give_back_terminal

	# Once a test file or config has loaded the debug gem, rather than by
	# wrapping `debugger`, as the gem shows the first frame outside itself as
	# where the test stopped. Stepping skips Quickdraw's frames.
	def hook_debug_gem
		return if @debug_gem_hooked || !worker || !defined?(DEBUGGER__::Session)

		DEBUGGER__::Session.prepend(DebugSessionMethods)
		DEBUGGER__::CONFIG.append_config(:skip_path, [%r{\A#{Regexp.escape(__dir__)}/}])
		@debug_gem_hooked = true
	end

	def flag_path
		ENV.fetch(FLAG)
	end

	# Whether a debugger, in any worker, has the terminal.
	def active?
		ENV.key?(FLAG) && File.exist?(ENV[FLAG])
	end

	# Whether this process's debugger has the terminal.
	def holding?
		worker&.has_terminal? || false
	end

	# Not in a process a test forked.
	private def worker
		@worker if @pid == Process.pid
	end
end
