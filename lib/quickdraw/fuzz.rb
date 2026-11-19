# frozen_string_literal: true

# Fuzzing, for `quickdraw fuzz`: runs a test's property for a time rather than
# a number of cases, keeping the cases that reach new code (the corpus, see
# Corpus and Edges) and making new ones by changing their choices (see
# Mutator). Runner drives a Session in each worker, which forks a Fuzzer to
# do the work, so a case can crash or hang it.
#
# Everything but Runner runs in workers, so it must only use core Ruby.
module Quickdraw::Fuzz
	extend self

	autoload :Edges, "quickdraw/fuzz/edges"
	autoload :Mutator, "quickdraw/fuzz/mutator"
	autoload :Corpus, "quickdraw/fuzz/corpus"
	autoload :Fuzzer, "quickdraw/fuzz/fuzzer"
	autoload :Attempt, "quickdraw/fuzz/attempt"
	autoload :Session, "quickdraw/fuzz/session"
	autoload :Runner, "quickdraw/fuzz/runner"

	# Something a fuzzer found: a case that fails, minimised. `kind` is
	# "failed", "errored", "crashed" or "hung". `key` names its property (see
	# Property), `cases` is how many the fuzzer had run when it found it,
	# and `input` and `original` are the minimal and found cases' values.
	Finding = Data.define(:kind, :key, :choices, :input, :original, :failure, :cases, :shrinks) do
		def self.kind(failure)
			case failure.errors.first&.fetch("name")
			in "Quickdraw::Fuzz::Crash" then "crashed"
			in "Quickdraw::Fuzz::Hang" then "hung"
			in String then "errored"
			in nil then "failed"
			end
		end
	end

	# Stands in for an error when a case crashed or hung the process.
	def failure(name, message)
		Quickdraw::Property::Failure.new(failures: [], errors: [{ "name" => name, "message" => message, "backtrace" => [] }])
	end

	# In a process a Session forked, what takes the test's first property:
	# a Fuzzer, or an Attempt at one case.
	attr_writer :fuzzer

	# The waiting fuzzer, once: later and nested properties run as usual.
	def claim
		fuzzer = @fuzzer
		@fuzzer = nil
		fuzzer
	end
end
