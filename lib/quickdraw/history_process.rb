# frozen_string_literal: true

# Records a run in its history (see History) from a process of its own,
# started when the run starts, so sqlite3, which takes ~35ms to load, loads
# while the tests run, and never in the coordinator, which forks loaders. It
# takes the run's results as they come, so few are left to send at the end.
# What the run needs from history before it starts comes from the plan the
# run before wrote (see History.plan), which needs no sqlite3.
#
# Sending is on the run's critical path, so each file's tests are sent once,
# and a passing test's result is only numbers, packed with a batch's others.
# History::Records are built from them in the history process.
class Quickdraw::HistoryProcess
	# Results sent at a time.
	BATCH = 500
	ALLOCATIONS = Quickdraw::STATS.index("allocations")

	# What the history process is sent, as the History::Records to save.
	class Records
		# A passing test's numbers: its file's number, its index, assertions,
		# worker, slot, sequence and duration, then its stats.
		PASSED = "E*"
		PASSED_SIZE = 7 + Quickdraw::STATS.size

		def initialize
			@files = []
			@records = []
		end

		def to_a = @records

		def receive(message)
			case message
			in [:file, path, keys, lines, undescribed]
				@files << [path, keys, lines, undescribed.to_h { |index| [index, true] }]
			in [:passed, packed]
				packed.unpack(PASSED).each_slice(PASSED_SIZE) do |file, index, assertions, worker, slot, sequence, duration, *stats|
					stats[ALLOCATIONS] = stats[ALLOCATIONS].to_i
					add(file.to_i, index.to_i, "passed", duration, stats, assertions.to_i, nil, worker.to_i, slot.to_i, sequence.to_i)
				end
			in [:others, results]
				results.each { |result| add(*result) }
			end
		end

		private def add(file, index, status, duration, stats, assertions, details, worker, slot, sequence)
			path, keys, lines, undescribed = @files.fetch(file)

			@records << Quickdraw::History::Record.new(
				key: keys.fetch(index),
				path:,
				line: lines.fetch(index),
				described: !undescribed.key?(index),
				status:,
				duration:,
				stats:,
				assertions:,
				details:,
				worker:,
				slot:,
				sequence:,
			)
		end
	end

	# Without fork, it records in this process when the run ends, where tests
	# already share a process with the coordinator anyway.
	def initialize(path)
		@path = path
		@files = {}.compare_by_identity
		@passed = []
		@others = []
		@waiting = 0
		# What #add couldn't write yet.
		@unsent = "".b

		unless Process.respond_to?(:fork)
			@records = Records.new
			return
		end

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

	# Takes the result of the test at `index` in `file`, a Coordinator::TestFile
	# with history keys, and where it ran. Results are sent as the run goes, so
	# there are fewer to send when it ends.
	def add(file, index, result, worker, slot, sequence)
		# The process has gone, so saving will fail.
		return unless @unsent

		id = @files[file] || announce(file)
		status = Quickdraw::History.status(result)
		duration = result["duration"]
		stats = result["stats"]

		if status == "passed" && duration && stats
			@passed.push(id, index, result["assertions"], worker, slot, sequence, duration).concat(stats)
		else
			details = { "failures" => result["failures"], "errors" => result["errors"] } unless status == "passed"
			@others << [id, index, status, duration, stats, result["assertions"], details, worker, slot, sequence]
		end

		send_results if (@waiting += 1) >= BATCH
	end

	# Asks for the run (see History#record_run, but for its records) and the
	# coverage map, if any, to be recorded. Returns once the process holds the
	# history's write lock, then it writes and exits by itself, so the run can
	# end without waiting.
	def save(run, coverage_map)
		return false unless @unsent

		queue_results
		return record(Quickdraw::History.new(@path, wait: false), Quickdraw::History.lock_for_writing(@path), run.merge(records: @records.to_a), coverage_map) unless @channel

		@channel.writer.write(@unsent) unless @unsent.empty?
		@channel.write([:save, run, coverage_map]) && @channel.read
	rescue Errno::EPIPE
		false
	end

	# The process exits by itself once it has saved, or straight away if it wasn't asked to.
	def close
		return unless @channel

		@channel.close
		Process.detach(@pid)
	end

	# A file's tests, once, as their keys and lines, and which have no
	# description. Returns the number its results are sent with.
	private def announce(file)
		undescribed = []

		lines = file.tests.each_with_index.map do |test, index|
			undescribed << index unless test["description"]
			test["line"]
		end

		queue([:file, file.display_path, file.keys, lines, undescribed])
		@files[file] = @files.size
	end

	# Never waits, so a busy or stopped history process can't hold up the run;
	# what doesn't fit in the pipe goes with the next, or at the end.
	private def send_results
		queue_results
		return unless @channel

		written = @channel.writer.write_nonblock(@unsent, exception: false)
		@unsent = @unsent.byteslice(written..) if Integer === written
	rescue Errno::EPIPE
		@unsent = nil
	end

	private def queue_results
		queue([:passed, @passed.pack(Records::PASSED)]) if @passed.any?
		queue([:others, @others]) if @others.any?
		@passed.clear
		@others = []
		@waiting = 0
	end

	private def queue(message)
		if @channel
			@unsent << Quickdraw::Channel.encode(message)
		else
			@records.receive(message)
		end
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

		records = Records.new

		loop do
			case channel.read
			in [:save, run, coverage_map]
				begin
					lock = Quickdraw::History.lock_for_writing(path)
				rescue Quickdraw::History::Error => error
					warn "Quickdraw couldn’t save the run to its history (#{error.message})."
				end

				channel.write(:locked)
				record(opening.value, lock, run.merge(records: records.to_a), coverage_map) if lock
				break
			in nil
				break
			in message
				records.receive(message)
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
