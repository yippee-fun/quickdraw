# frozen_string_literal: true

# Records which lines of some methods (subjects) each test runs, so each
# mutant runs only the tests that reach it. Each method is traced on its own,
# so code elsewhere runs at full speed. `call` events count for the
# definition's line, since a one-line method's body has no line events.
class Quickdraw::Mutation::Tracer
	def initialize
		@trace_points = {}
		@hits = {}
	end

	# Starts tracing those of `subjects` that are defined now, and forgets what
	# ran so far. Returns the ids of every subject being traced.
	def trace(subjects)
		subjects.each do |subject|
			next if @trace_points.key?(subject.id)

			method = subject.defined_method or next
			id = subject.id
			trace_point = TracePoint.new(:line, :call) { |point| (@hits[id] ||= {})[point.lineno] = true }

			begin
				trace_point.enable(target: method)
			rescue ArgumentError
				# Nothing in it can be traced.
				next
			end

			@trace_points[id] = trace_point
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
