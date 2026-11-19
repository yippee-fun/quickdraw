# frozen_string_literal: true

# What a fuzzed case ran of the project's own code: each edge from one line to
# the next in its methods, with roughly how many times (see #take). A case
# with an edge or count no case had before reached new code.
#
# Each method is traced by a TracePoint of its own, so other code, such as
# gems, runs at full speed. Ruby's Coverage costs in proportion to all the code
# loaded since it started, every time it's read, which is once per case: 55µs
# with a few standard libraries loaded, and milliseconds with branches, against
# about 5µs for this on a small parser.
class Quickdraw::Fuzz::Edges
	# Read through Module's own methods, in case a class overrides them.
	INSTANCE_METHODS = Module.instance_method(:instance_methods)
	PRIVATE_INSTANCE_METHODS = Module.instance_method(:private_instance_methods)
	INSTANCE_METHOD = Module.instance_method(:instance_method)

	# A line is 12 bits of its path's hash and its line number in 16, so an
	# edge, with a count's bucket, fits in a Fixnum.
	LINE_BITS = 16
	LOCATION_MASK = (1 << 28) - 1

	def initialize(root = Quickdraw::ROOT)
		@root = "#{root}/"
		@counts = Hash.new(0)
		@previous = 0
		# Methods by where they're defined, so an alias isn't traced twice.
		@seen = {}
		@traced = 0
		@loaded_features = nil
	end

	# Starts tracing the project's methods defined since it last did, if files
	# have been loaded since, as an autoloader does as a case runs. Returns how
	# many methods are traced.
	def trace
		return @traced if $LOADED_FEATURES.size == @loaded_features

		@loaded_features = $LOADED_FEATURES.size

		ObjectSpace.each_object(Module) do |owner|
			(INSTANCE_METHODS.bind_call(owner, false) + PRIVATE_INSTANCE_METHODS.bind_call(owner, false)).each do |name|
				trace_method(INSTANCE_METHOD.bind_call(owner, name))
			end
		end

		@traced
	end

	# The edges run since it was last called, each with its count's bucket: 1,
	# 2–3, 4–7, … up to 64 or more. Then forgets them.
	def take
		features = @counts.map { |edge, count| (edge << 3) | (count.bit_length.clamp(1, 7)) }
		@counts.clear
		@previous = 0
		features
	end

	private def trace_method(method)
		location = method.source_location
		return unless location && !@seen.key?(location) && project?(location.first)

		@seen[location] = true
		# From the path, so every worker numbers it the same.
		file = (Quickdraw.stable_hash(location.first) << LINE_BITS) & LOCATION_MASK

		trace_point = TracePoint.new(:line) do |point|
			line = file | (point.lineno & 0xFFFF)
			@counts[(@previous << 28) | line] += 1
			@previous = line
		end

		trace_point.enable(target: method)
		@traced += 1
	rescue ArgumentError
		# A method without Ruby code to trace, such as attr_reader's.
		nil
	end

	private def project?(path)
		path.start_with?(@root) &&
			!path.start_with?(*Quickdraw::CoverageCollector::QUICKDRAW) &&
			!Quickdraw::CoverageCollector::EXCLUDED.match?(path.delete_prefix(@root))
	end
end
