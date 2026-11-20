# frozen_string_literal: true

# How each worker spent a run, for --timeline. The coordinator tells it when
# each worker starts, loads a file, is given a batch, sends a result and
# stops, and it keeps an array per event. Afterwards it divides each worker
# slot's time into PHASES, finds the tests still running once workers began
# to run out of work, and writes a chart of it all to PATH.
class Quickdraw::Timeline
	autoload :Page, "quickdraw/timeline/page"

	PATH = ".quickdraw/timeline.html"

	PHASES = {
		running: "running tests",
		between: "between tests",
		loading: "loading files",
		starting: "starting",
		waiting: "waiting for work",
		switching: "replacing workers",
		idle: "idle at the end",
	}.freeze

	# Seconds from the start of the run. `label` is [path, test] for :running,
	# and a path for :loading.
	Segment = Data.define(:phase, :from, :to, :label) do
		def duration = to - from
	end

	# A test that ran after the first worker ran out of work: `overlap` of its
	# `duration` came after that.
	Straggler = Data.define(:path, :test, :duration, :overlap)

	def initialize
		@started_at = now
		@events = []
		@added = []
		@stopped_at = nil
		@finished_at = nil
	end

	def spawned(worker) = @events << [now, worker.process, :spawn, worker.slot, worker.group]
	def loading(worker, path) = @events << [now, worker.process, :load, path]
	def running(worker, file, indices) = @events << [now, worker.process, :run, file, indices]
	def stopping(worker) = @events << [now, worker.process, :stop]
	def exited(worker) = @events << [now, worker.process, :exit]

	# Every message from a worker, as the coordinator reads it.
	def received(worker, message)
		case message
		in [:ready, _] then @events << [now, worker.process, :ready]
		in [:started] then @events << [now, worker.process, :started]
		in [:loaded | :load_failed, _, *] then @events << [now, worker.process, :loaded]
		in [:result, index, result] then @events << [now, worker.process, :result, index, result["duration"]]
		else nil
		end
	end

	# Workers added during the run (see Elastic), as [seconds, how many].
	attr_reader :added

	def add(count)
		@added << [now - @started_at, count]
	end

	# When every worker has been told to stop, at the end. The coordinator
	# says so again while they exit.
	def stopped
		@stopped_at ||= now
	end

	def finish
		@finished_at = now
		@stopped_at ||= @finished_at
	end

	# Seconds from the start of the run, which includes booting config, to the end.
	def duration = @finished_at - @started_at

	# Until the first worker started.
	def boot_time = (@events.first&.first || @finished_at) - @started_at

	# When every worker had finished and was told to stop, in seconds.
	def stopped_at = @stopped_at - @started_at

	# From the end of the last test until the workers and loaders exited.
	def shutdown_time = @finished_at - @stopped_at

	# { slot => [Segment] } from when the slot's first worker started until
	# every worker was told to stop.
	def slots
		@slots ||= @events.group_by { |_time, process| process }.each_value
			.group_by { |events| slot_of(events) }
			.sort
			.to_h { |slot, processes| [slot, arrange(processes.flat_map { |events| segments(events) })] }
	end

	# Which group each slot's last worker ran tests for.
	def groups
		@events.select { |_time, _process, event| event == :spawn }.to_h { |_time, _process, _event, slot, group| [slot, group] }
	end

	# { phase => seconds } across every slot.
	def phases
		@phases ||= slots.each_value.with_object(PHASES.transform_values { 0.0 }) do |segments, totals|
			segments.each { |segment| totals[segment.phase] += segment.duration }
		end
	end

	def worker_time = phases.each_value.sum

	# When the first worker ran out of work for good, or nil if none did.
	def ran_out_at
		slots.each_value.filter_map { |segments| segments.find { |segment| segment.phase == :idle }&.from }.min
	end

	# The tests that ran longest after the first worker ran out of work,
	# longest first.
	def stragglers(limit)
		from = ran_out_at or return []

		slots.each_value
			.flat_map { |segments| segments.select { |segment| segment.phase == :running && segment.to > from } }
			.map { |segment| Straggler.new(path: segment.label[0], test: segment.label[1], duration: segment.duration, overlap: segment.to - [segment.from, from].max) }
			.max_by(limit, &:overlap)
	end

	def write
		require "fileutils"
		FileUtils.mkdir_p(File.dirname(PATH))
		File.write(PATH, Page.new(self).call)
	end

	# Lines for the end of the run, pointing to the chart.
	def summary(color:)
		lines = [
			"#{style('Timeline', 1, color)} #{style(PATH, 2, color)}",
			"  #{seconds(boot_time)} booting · #{seconds(stopped_at - boot_time)} running tests · #{seconds(shutdown_time)} stopping",
		]

		total = worker_time
		return lines unless total > 0

		shares = PHASES.filter_map do |phase, name|
			share = phases[phase] / total
			"#{(share * 100).round}% #{name}" if phase == :running || share >= 0.01
		end

		lines << "  #{slots.size} workers#{added_note}: #{shares.join(' · ')}"

		if phases[:idle] / total >= 0.05 && (stragglers = stragglers(3)).any?
			lines << "  For the last #{seconds(stopped_at - ran_out_at)}, workers ran out of work while these ran:"
			stragglers.each { |straggler| lines << "    #{seconds(straggler.duration).rjust(6)}  #{straggler.path}:#{straggler.test['line']} #{Quickdraw::Filter.name_of(straggler.test)}" }
		end

		lines
	end

	private def added_note
		count = @added.sum { |_at, added| added }
		" (#{count} added while running)" if count > 0
	end

	private def seconds(value) = format("%.2fs", value)

	private def style(text, code, color) = color ? "\e[#{code}m#{text}\e[0m" : text

	private def slot_of(events)
		events.first => [_time, _process, :spawn, slot, _group]
		slot
	end

	# One worker process's segments, from its events.
	private def segments(events)
		segments = []
		phase = since = label = batch = indices = nil
		results = 0
		begun = false

		events.each do |time, _process, event, *detail|
			time -= @started_at

			if event == :started
				begun = true
				next
			end

			if event == :result
				index, nanoseconds = detail
				started = [time - (nanoseconds / 1e9), since].max
				segments << Segment.new(phase: :between, from: since, to: started, label: nil)
				segments << Segment.new(phase: :running, from: started, to: time, label: [batch.display_path, batch.tests[index]])
				since = time
				results += 1
				next
			end

			# A test that crashed its worker ran until it exited. Without
			# :started, the worker never began the batch.
			if event == :exit && phase == :between && begun && (index = indices[results])
				phase, label = :running, [batch.display_path, batch.tests[index]]
			end

			segments << Segment.new(phase:, from: since, to: time, label:) if phase

			phase, label = case event
			in :spawn then [:starting, nil]
			in :load then [:loading, detail.first]
			in :run then [:between, nil]
			in :ready | :loaded then [:waiting, nil]
			in :stop then [:switching, nil]
			in :exit then [nil, nil]
			end

			if event == :run
				batch, indices = detail
				results = 0
				begun = false
			end

			since = time
		end

		segments << Segment.new(phase:, from: since, to: @finished_at - @started_at, label:) if phase
		segments.select { |segment| segment.to > segment.from }
	end

	# A slot's segments in order, with the gaps between its workers, up to when
	# the last test finished. Waiting after its last work is idle.
	private def arrange(segments)
		arranged = []

		segments.sort_by(&:from).each do |segment|
			last = arranged.last
			arranged << Segment.new(phase: :switching, from: last.to, to: segment.from, label: nil) if last && segment.from > last.to
			arranged << segment
		end

		return [] if arranged.empty?

		ended = stopped_at
		arranged << Segment.new(phase: :switching, from: arranged.last.to, to: ended, label: nil) if arranged.last.to < ended
		arranged = arranged.select { |segment| segment.from < ended }.map { |segment| (segment.to > ended) ? segment.with(to: ended) : segment }
		last_work = arranged.rindex { |segment| segment.phase in :running | :between | :loading | :starting } || -1

		arranged.each_with_index.map do |segment, index|
			(index > last_work && (segment.phase in :waiting | :switching)) ? segment.with(phase: :idle) : segment
		end
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
