# frozen_string_literal: true

# Records a run in its history (see History) from a process of its own,
# started when the run starts, so sqlite3, which takes ~35ms to load, loads
# while the tests run, and never in the coordinator, which forks loaders.
# What the run needs from history before it starts comes from the plan the
# run before wrote (see History.plan), which needs no sqlite3.
class Quickdraw::HistoryProcess
	# Without fork, it records in this process when the run ends, where tests
	# already share a process with the coordinator anyway.
	def initialize(path)
		@path = path
		return unless Process.respond_to?(:fork)

		@channel, history_channel = Quickdraw::Channel.pair

		@pid = Process.fork do
			@channel.close
			# It finishes writing after the run has ended, so it leaves the run's
			# process group, which a terminal, CI or a test may stop as a whole.
			Process.setpgid(0, 0)
			trap("INT", "IGNORE")
			serve(history_channel, path)
		end

		history_channel.close
	end

	# For processes forked from the coordinator, which mustn't hold its pipe open.
	def disconnect
		@channel&.close
	end

	# Asks for the run (see History#record_run) and the coverage map, if any,
	# to be recorded. Returns once the process holds the history's write lock,
	# then it writes and exits by itself, so the run can end without waiting.
	def save(run, coverage_map)
		return record(Quickdraw::History.new(@path, wait: false), Quickdraw::History.lock_for_writing(@path), run, coverage_map) unless @channel

		@channel.write([:save, run, coverage_map]) && @channel.read
	end

	# The process exits by itself once it has saved, or straight away if it wasn't asked to.
	def close
		return unless @channel

		@channel.close
		Process.detach(@pid)
	end

	# With exit!, since this is a fork of the coordinator, whose at_exit hooks
	# aren't its own.
	private def serve(channel, path)
		opening = Thread.new do
			Quickdraw::History.new(path, wait: false)
		rescue Quickdraw::History::Error => error
			error
		end

		case channel.read
		in [:save, run, coverage_map]
			begin
				lock = Quickdraw::History.lock_for_writing(path)
			rescue Quickdraw::History::Error => error
				warn "Quickdraw couldn’t save the run to its history (#{error.message})."
			end

			channel.write(:locked)
			record(opening.value, lock, run, coverage_map) if lock
		else nil
		end

		exit!(0)
	end

	# After the run has ended, so problems go straight to stderr.
	private def record(history, lock, run, coverage_map)
		raise history if Quickdraw::History::Error === history

		history.write_lock = lock
		history.record_run(**run)
		history.record_coverage_map(coverage_map) if coverage_map
		history.save_plan(run[:selection])
		history.close
	rescue Quickdraw::History::Error, SystemCallError => error
		warn "Quickdraw couldn’t save the run to its history (#{error.message})."
	end
end
