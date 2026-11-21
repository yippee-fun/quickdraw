# frozen_string_literal: true

# Records a run in its history (see History) from a process of its own,
# started when the run starts, so sqlite3, which takes ~35ms to load, loads
# while the tests run, and never in the coordinator, which forks loaders. It
# takes the run's records as they come, so few are left to send at the end.
# What the run needs from history before it starts comes from the plan the
# run before wrote (see History.plan), which needs no sqlite3.
class Quickdraw::HistoryProcess
	# Without fork, it records in this process when the run ends, where tests
	# already share a process with the coordinator anyway.
	def initialize(path)
		@path = path
		# Without fork, records added as the run goes.
		@records = []
		# What #add couldn't write yet.
		@unsent = "".b
		return unless Process.respond_to?(:fork)

		@channel, history_channel = Quickdraw::Channel.pair

		@pid = Process.fork do
			@channel.close
			# It finishes writing after the run has ended, so it leaves the run's
			# process group, which a terminal, CI or a test may stop as a whole.
			Process.setpgid(0, 0)
			trap("INT", "IGNORE")
			# Whatever reads the run's output through a pipe would wait for this
			# process too, which holds the pipe open until it exits. Only stderr
			# says what went wrong, so it's kept unless it's a pipe.
			$stdout.reopen(File::NULL)
			$stderr.reopen(File::NULL) if $stderr.stat.pipe? || $stderr.stat.socket?
			serve(history_channel, path)
		end

		history_channel.close
	end

	# Without fork, whether sqlite3, which records the run in this process, loads.
	def recordable?
		return true if @channel

		require "sqlite3"
		true
	rescue LoadError
		false
	end

	# For processes forked from the coordinator, which mustn't hold its pipe open.
	def disconnect
		@channel&.close
	end

	# Sends History::Records as the run goes, so there are fewer to send when it
	# ends. Never waits, so a busy or stopped history process can't hold up the
	# run; what doesn't fit in the pipe goes with the next, or at the end.
	def add(records)
		return @records.concat(records) unless @channel
		# The process has gone, so saving will fail.
		return unless @unsent

		@unsent << Quickdraw::Channel.encode([:records, records])
		written = @channel.writer.write_nonblock(@unsent, exception: false)
		@unsent = @unsent.byteslice(written..) if Integer === written
	rescue Errno::EPIPE
		@unsent = nil
	end

	# Asks for the run (see History#record_run) and the coverage map, if any,
	# to be recorded. Returns once the process holds the history's write lock,
	# then it writes and exits by itself, so the run can end without waiting.
	# Raises History::Error if it had failed by then.
	def save(run, coverage_map)
		return record(Quickdraw::History.new(@path, wait: false), Quickdraw::History.lock_for_writing(@path), run.merge(records: @records + run[:records]), coverage_map) unless @channel

		return false unless @unsent

		@channel.writer.write(@unsent) unless @unsent.empty?
		return false unless @channel.write([:save, run, coverage_map])

		case @channel.read
		in [:failed, message] then raise Quickdraw::History::Error, message
		in reply then reply
		end
	rescue Errno::EPIPE
		false
	end

	# The process exits by itself once it has saved, or straight away if it wasn't asked to.
	def close
		return unless @channel

		@channel.close
		Process.detach(@pid)
	end

	# With exit!, since this is a fork of the coordinator, whose at_exit hooks
	# aren't its own.
	# Opening the history snapshots the code being run, so it's opened as the
	# run starts.
	private def serve(channel, path)
		opening = Thread.new do
			Quickdraw::History.new(path, wait: false)
		rescue Quickdraw::History::Error => error
			error
		end

		records = []

		loop do
			case channel.read
			in [:records, batch]
				records.concat(batch)
			in [:save, run, coverage_map]
				# What has already failed goes to the run to say, since this
				# process's stderr may go nowhere.
				begin
					raise opening.value if !opening.alive? && Quickdraw::History::Error === opening.value

					lock = Quickdraw::History.lock_for_writing(path)
				rescue Quickdraw::History::Error => error
					channel.write([:failed, error.message])
					break
				end

				channel.write(:locked)
				record(opening.value, lock, run.merge(records: records.concat(run[:records])), coverage_map)
				break
			else break
			end
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
