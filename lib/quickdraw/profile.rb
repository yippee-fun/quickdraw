# frozen_string_literal: true

# Where test time went, from --profile's samples (see Sampler): each method's
# share of the time sampled, and how many tests it ran in. A method in most
# tests with a large share is a shared cost, such as a slow factory or setup
# hook, worth fixing once rather than test by test.
class Quickdraw::Profile
	# `share` is of the time with the method anywhere on the stack, `self_share`
	# with it innermost. `line` is where it's defined, when that's known.
	Method = Data.define(:label, :path, :line, :share, :self_share, :tests)

	def initialize
		@samples = 0
		@sampled = 0.0
		@tests = 0
		@methods = {}
	end

	attr_reader :samples, :tests

	def record(result)
		count, sampled, methods = result["profile"]
		return unless count

		@samples += count
		@sampled += sampled
		@tests += 1

		methods.each do |key, (inclusive, innermost)|
			totals = (@methods[key] ||= [0.0, 0.0, 0])
			totals[0] += inclusive
			totals[1] += innermost
			totals[2] += 1
		end
	end

	def any? = @sampled > 0

	# The methods with the largest share, largest first.
	def top(limit)
		return [] unless any?

		@methods.max_by(limit) { |_key, (inclusive, *)| inclusive }.map do |key, (inclusive, innermost, tests)|
			label, path, line = key.split("\0", 3)
			# Without the anonymous module each test file is loaded in.
			label = label.gsub(/#<Module:0x\h+>(?:::|#)/, "")
			line = line.empty? ? nil : Integer(line, 10)
			Method.new(label:, path:, line:, share: inclusive / @sampled, self_share: innermost / @sampled, tests:)
		end
	end
end
