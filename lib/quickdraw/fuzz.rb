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

	# What a Session sends a process whose case has run too long.
	HANG_SIGNAL = "USR2"

	# Something a fuzzer found: a case that fails, minimised. `kind` is
	# "failed", "errored", "crashed" or "hung". `key` names its property (see
	# Property), `cases` is how many the fuzzer had run when it found it,
	# and `input` and `original` are the minimal and found cases' values.
	# `choices` and `input` are nil for a case that crashed or hung the process
	# before its generators finished, which can't be replayed.
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
	def failure(name, message, backtrace = [])
		Quickdraw::Property::Failure.new(failures: [], errors: [{ "name" => name, "message" => message, "backtrace" => backtrace }])
	end

	# In a process a Session forked: on HANG_SIGNAL, writes where the thread
	# running the property is to `channel` as [:hung, backtrace], and exits.
	# Without the channel's lock, which a trap can't take. A process a case
	# forks gets the signal's default.
	def report_hangs(channel)
		pid = Process.pid

		Signal.trap(HANG_SIGNAL) do
			unless Process.pid == pid
				Signal.trap(HANG_SIGNAL, "DEFAULT")
				Process.kill(HANG_SIGNAL, Process.pid)
				next
			end

			channel.writer.write(Quickdraw::Channel.encode([:hung, project_backtrace((@property_thread || Thread.current).backtrace || [])]))
			exit!(0)
		end
	end

	# Quickdraw's aside, the frames from the innermost in the project (outside
	# vendor/), so a hang's signature (see Property::Failure) is where in the
	# project it hung. All of them if none is.
	def project_backtrace(frames)
		frames = frames.reject { |frame| frame.start_with?("#{Quickdraw::LIB}/") }
		project = frames.drop_while { |frame| !frame.start_with?("#{Quickdraw::ROOT}/") || frame.start_with?("#{Quickdraw::ROOT}/vendor/") }
		project.empty? ? frames : project
	end

	# In a process a Session forked, what takes the test's first property:
	# a Fuzzer, or an Attempt at one case.
	attr_writer :fuzzer

	# The waiting fuzzer, once: later and nested properties run as usual.
	def claim
		fuzzer = @fuzzer
		@fuzzer = nil
		@property_thread = Thread.current if fuzzer
		fuzzer
	end
end
