# frozen_string_literal: true

# Records which lines of some methods and blocks (subjects) each test runs, so
# each mutant runs only the tests that reach it. Each is traced on its own, so
# code elsewhere runs at full speed. `call` and `b_call` events count for the
# line it opens on, since a one-line method's body has no line events.
class Quickdraw::Mutation::Tracer
	def initialize
		@trace_points = {}
		@hits = {}
	end

	# Starts tracing those of `subjects` that are defined now, and forgets what
	# ran so far. Returns the ids of every subject being traced.
	def trace(subjects)
		subjects = subjects.reject { |subject| @trace_points.key?(subject.id) }
		blocks = Quickdraw::Mutation::Subject.blocks(subjects)

		subjects.each do |subject|
			targets = subject.block ? blocks.fetch(subject.id, []) : [subject.defined_method].compact
			id = subject.id

			targets.each do |target|
				trace_point = TracePoint.new(:line, :call, :b_call) { |point| (@hits[id] ||= {})[point.lineno] = true }
				trace_point.enable(target:)
				(@trace_points[id] ||= []) << trace_point
			rescue ArgumentError
				# Nothing in it can be traced.
				nil
			end
		end

		@hits = {}
		@trace_points.keys
	end

	# What ran since last taken, as { subject id => [lines] }.
	def take
		hits = @hits.transform_values(&:keys)
		@hits = {}
		hits
	end
end
