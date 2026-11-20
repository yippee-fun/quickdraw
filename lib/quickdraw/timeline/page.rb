# frozen_string_literal: true

require "phlex"
# Phlex 2.4 checks attribute values against Date without requiring it.
require "date"

# A Timeline as a page that works from disk: what workers' time went on, a
# chart of each worker slot, and the tests the run waited for at the end.
# Loads Phlex, so only the coordinator may load it, after the run.
class Quickdraw::Timeline::Page < Phlex::HTML
	STYLES = File.read(File.join(__dir__, "styles.css")).freeze

	# Neighbouring segments narrower than this share of the chart are drawn as
	# one, since each would be too narrow to see or point at.
	NARROW = 0.005

	STEPS = [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600].freeze

	EXPLANATIONS = {
		running: "Inside tests, as workers time them, hooks included.",
		between: "In a batch but not in a test: sending results, checking for leaks and capturing output, and from the batch being sent to its first test starting.",
		loading: "Loading test files. Each worker loads the files it runs tests from.",
		starting: "From a worker forking until it’s ready, after_forking callbacks included.",
		waiting: "Ready for work while other workers were busy: waiting for the coordinator, or for a slow file another worker was loading.",
		switching: "From a worker stopping until another starts in its slot: to move to another group, retry a failure in a fresh worker, or replace one that crashed.",
		idle: "After a slot’s last work, while other workers finished theirs.",
	}.freeze

	Block = Data.define(:phase, :from, :to, :title)

	def initialize(timeline)
		@timeline = timeline
		@duration = timeline.duration
	end

	def view_template
		doctype

		html(lang: "en") do
			head do
				meta(charset: "utf-8")
				meta(name: "viewport", content: "width=device-width, initial-scale=1")
				title { "Timeline" }
				style { raw(safe(STYLES)) }
			end

			body do
				main do
					h1 { "Timeline" }
					p(class: "muted") do
						"#{@timeline.slots.size} workers · #{seconds(@duration)}: #{seconds(@timeline.boot_time)} booting config, " \
							"#{seconds(@timeline.stopped_at - @timeline.boot_time)} running tests, #{seconds(@timeline.shutdown_time)} stopping"
					end

					shares
					chart
					stragglers
					explanations
				end
			end
		end
	end

	private def shares
		total = @timeline.worker_time
		return unless total > 0

		h2 { "Workers’ time" }

		div(class: "shares") do
			@timeline.phases.each do |phase, time|
				span(class: phase, style: "width: #{percent(time / total)}%", title: Quickdraw::Timeline::PHASES.fetch(phase))
			end
		end

		ul(class: "legend") do
			@timeline.phases.each do |phase, time|
				next if time == 0

				li do
					span(class: ["swatch", phase])
					plain "#{Quickdraw::Timeline::PHASES.fetch(phase)} "
					span(class: "muted") { "#{(time * 100 / total).round(1)}% · #{seconds(time)}" }
				end
			end
		end
	end

	private def chart
		h2 { "Workers" }
		groups = @timeline.groups

		div(class: "chart") do
			span
			axis

			@timeline.slots.each do |slot, segments|
				span(class: "label") { ["Worker #{slot}", groups[slot]].compact.join(" · ") }

				div(class: "track") do
					span(class: "outside", style: position(0, @timeline.boot_time), title: "Booting config: #{seconds(@timeline.boot_time)}")
					blocks(segments).each { |block| span(class: block.phase, style: position(block.from, block.to), title: block.title) }
					span(class: "outside", style: position(@timeline.stopped_at, @duration), title: "Stopping: #{seconds(@timeline.shutdown_time)}")

					@timeline.added.each do |at, count|
						span(class: "added", style: "left: #{percent(at / @duration)}%", title: "#{count} workers added")
					end
				end
			end
		end
	end

	private def axis
		step = STEPS.find { |candidate| @duration / candidate <= 10 } || STEPS.last

		div(class: "axis") do
			1.upto((@duration / step).floor) do |tick|
				at = tick * step
				span(style: "left: #{percent(at / @duration)}%") { (step < 1) ? format("%.2gs", at) : "#{at.round}s" }
			end
		end
	end

	private def stragglers
		stragglers = @timeline.stragglers(10)
		return if stragglers.empty?

		h2 { "At the end" }
		p(class: "muted") do
			"For the last #{seconds(@timeline.stopped_at - @timeline.ran_out_at)} of running tests, from #{seconds(@timeline.ran_out_at)}, " \
				"workers ran out of work. These tests ran longest in that time:"
		end

		table do
			thead do
				tr do
					th { "Test" }
					th { "Took" }
					th { "After" }
				end
			end

			tbody do
				stragglers.each do |straggler|
					tr do
						td do
							code { "#{straggler.path}:#{straggler.test['line']}" }
							plain " #{Quickdraw::Filter.name_of(straggler.test)}"
						end
						td { seconds(straggler.duration) }
						td { seconds(straggler.overlap) }
					end
				end
			end
		end
	end

	private def explanations
		h2 { "Phases" }

		dl do
			EXPLANATIONS.each do |phase, explanation|
				dt do
					span(class: ["swatch", phase])
					plain Quickdraw::Timeline::PHASES.fetch(phase)
				end
				dd { explanation }
			end
		end
	end

	# Runs of narrow segments become one block, in whichever phase took most of it.
	private def blocks(segments)
		segments.chunk_while { |segment, following| narrow?(segment) && narrow?(following) }.map do |run|
			next block(run.first) if run.one?

			phase, = run.group_by(&:phase).max_by { |_phase, members| members.sum(&:duration) }
			tests = run.select { |segment| segment.phase == :running }
			paths = tests.map { |segment| segment.label[0] }.uniq
			title = if tests.any?
				"#{tests.size} tests in #{seconds(run.last.to - run.first.from)}, from #{paths.first}#{" and #{paths.size - 1} other files" if paths.size > 1}"
			else
				"#{Quickdraw::Timeline::PHASES.fetch(phase)}: #{seconds(run.last.to - run.first.from)}"
			end

			Block.new(phase:, from: run.first.from, to: run.last.to, title:)
		end
	end

	private def block(segment)
		title = case segment
		in { phase: :running, label: [path, test] } then "#{path}:#{test['line']} #{Quickdraw::Filter.name_of(test)}: #{seconds(segment.duration)}"
		in { phase: :loading, label: String => path } then "Loading #{path}: #{seconds(segment.duration)}"
		in { phase: } then "#{Quickdraw::Timeline::PHASES.fetch(phase).capitalize}: #{seconds(segment.duration)}"
		end

		Block.new(phase: segment.phase, from: segment.from, to: segment.to, title:)
	end

	private def narrow?(segment)
		(segment.phase in :running | :between | :waiting) && segment.duration < @duration * NARROW
	end

	private def position(from, to)
		"left: #{percent(from / @duration)}%; width: #{percent((to - from) / @duration)}%"
	end

	private def percent(share) = (share * 100).round(3)

	private def seconds(value) = (value < 1) ? "#{(value * 1000).round}ms" : format("%.2fs", value)
end
