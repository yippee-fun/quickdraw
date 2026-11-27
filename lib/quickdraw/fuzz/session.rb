# frozen_string_literal: true

# Fuzzes a test's first property in a worker, for `quickdraw fuzz`, until its
# time is up. The fuzzing happens in a fork of the worker (see Fuzzer), so a
# case that crashes or hangs costs only that process: the session reads the
# case it was running, minimises it with a fork for each attempt (see
# Attempt), reports it, and fuzzes on in a new fork, which skips that case.
#
# Writes to `channel` as it goes: [:fuzz_started, methods traced],
# [:fuzz_progress, cases, new features, corpus size] and [:fuzz_finding,
# Finding]; then [:fuzzed, outcome], which is ["fuzzed"], or ["fuzzed",
# error] if the test failed after fuzzing (in a later property or teardown,
# say), ["untargeted"] for a test fuzz didn't define (unless it was asked for
# by line), ["unchecked"] if the test checked no property, or ["errored",
# error] if it failed, crashed or hung before it did.
class Quickdraw::Fuzz::Session
	# How often to check that a forked process is still alive while waiting for
	# it, since a process it started can hold its pipe open.
	LIVENESS_INTERVAL = 0.1

	# How long a hung process has to say where it is.
	HANG_GRACE = 0.5

	# What a test that finished after fuzzing, but not as usual, reports.
	NOTHING = Quickdraw.deep_freeze({ "failures" => [], "errors" => [] })

	# `timeout` is how long a case may run before it counts as hanging, and
	# `seed` seeds the fuzzer. `test_seed` seeds `rand` in the test, as test
	# runs do. `explicit` fuzzes a test even if fuzz didn't define it.
	def initialize(channel, definition, seconds:, timeout:, seed:, test_seed:, explicit:)
		@channel = channel
		@definition = definition
		@seconds = seconds
		@timeout = timeout
		@seed = seed
		@test_seed = test_seed
		@explicit = explicit
		@signatures = {}
		@drawing_signatures = {}
		@inputs = {}
		@exits = {}
		@cases = 0
	end

	def call
		return @channel.write([:fuzzed, ["untargeted"]]) unless @explicit || target?
		# A pending test has nothing to run.
		return @channel.write([:fuzzed, ["unchecked"]]) unless @definition.block

		# The test's own, as fuzz(…, hang_after: 30) sets it.
		@timeout = fuzz_target&.hang_after || @timeout
		@last_case = open_last_case
		deadline = now + @seconds
		skip = []
		forks = 0

		outcome = loop do
			forks += 1
			@last_case.truncate(0)
			seed = Quickdraw.stable_hash("#{@seed}:#{forks}")
			pid, channel = fork_test { |writer| Quickdraw::Fuzz::Fuzzer.new(writer, @last_case, deadline:, seed:, skip:, signatures: @signatures) }

			case watch(pid, channel)
			in [:finished, result]
				problem = result["errors"].first || result["failures"].first
				break ["fuzzed", problem].compact if @key
				break ["unchecked"] unless problem

				break ["errored", problem]
			in [:broke, error]
				break ["errored", error]
			in [:died, failure]
				cases, stage, choices = read_last_case
				break ["errored", failure.errors.first] unless cases

				# Those since its last progress.
				@channel.write([:fuzz_progress, cases - @fork_cases, [], 0])
				@cases += cases - @fork_cases

				case stage
				in :running
					skip << choices
					report(choices, failure) unless @signatures.key?(failure.signature)
				in :replaying
					skip << choices
					report_drawing(failure)
				in :drawing
					report_drawing(failure)
				end

				break ["fuzzed"] if now > deadline
			end
		end

		@channel.write([:fuzzed, outcome])
	ensure
		@last_case&.close
	end

	private def target? = !!fuzz_target

	private def fuzz_target
		test_class = @definition.test_class
		test_class.fuzz_target(@definition.block) if test_class <= Quickdraw::Test
	end

	# Relays the fuzzer's messages until the test finishes: [:finished, result],
	# or [:died, failure] if a case crashed or hung the process or raised past
	# the property, or [:broke, error] if it did any of that before fuzzing.
	# After fuzzing, the test runs its other properties as usual, and only
	# finishing matters.
	private def watch(pid, channel)
		limit = test_timeout
		fuzzing = false
		done = false
		@fork_cases = 0

		loop do
			case receive(channel, pid, limit)
			in :timeout
				return [:finished, NOTHING] if done
				return [:died, hang(pid, channel)] if fuzzing

				return [:broke, timed_out]
			in [:fuzzing, key, traced]
				@key = key
				fuzzing = true
				limit = @timeout + Quickdraw::Fuzz::Fuzzer::INTERVAL
				@channel.write([:fuzz_started, traced])
			in [:progress, cases, features, corpus]
				@cases += cases
				@fork_cases += cases
				@channel.write([:fuzz_progress, cases, features, corpus])
			in [:finding, finding]
				@channel.write([:fuzz_finding, finding])
			# Not on finding it, so a fuzzer restarted while shrinking shrinks it again.
			in [:shrunk, signature]
				@signatures[signature] = true
			in [:done]
				done = true
				fuzzing = false
				limit = test_timeout
			in [:finished, result] if fuzzing && result["errors"].any?
				return [:died, Quickdraw::Property::Failure.new(failures: result["failures"], errors: result["errors"])]
			in [:finished, result]
				return [:finished, result]
			# The process was sent HANG_SIGNAL by something else, and exits.
			in [:hung, _] | nil
				return [:finished, NOTHING] if done

				crash = Quickdraw::Fuzz.failure("Quickdraw::Fuzz::Crash", "The process #{exit_reason(pid)}.")
				return fuzzing ? [:died, crash] : [:broke, crash.errors.first]
			end
		end
	ensure
		channel.close
		stop(pid)
	end

	# Minimises a case that crashed or hung the process, or raised past the
	# property, by running each attempt in a fork, and reports it.
	private def report(choices, failure)
		@signatures[failure.signature] = true
		run = attempt(choices)

		unless run&.failure && run.failure.signature == failure.signature
			error, *errors = failure.errors
			again = error.merge("message" => "#{error['message']} It didn’t when run again on its own, so it may depend on what earlier cases did, or on chance.")

			return finding(choices, failure.with(errors: [again, *errors]), input: @inputs[choices] || choices.inspect, original: nil, shrinks: 0)
		end

		shrinker = Quickdraw::Property::Shrinker.new(run) { |attempted| attempt(attempted) }
		minimal = shrinker.call
		finding(minimal.choices, minimal.failure, input: @inputs[minimal.choices], original: @inputs[run.choices], shrinks: shrinker.shrinks)
	end

	# Reports a case that crashed or hung the process, or raised past the
	# property, before its generators finished, as it has no choices to replay.
	# Apart from failures with choices, since a crash's signature is always
	# the same, and one in the property's block can still be replayed.
	private def report_drawing(failure)
		return if @drawing_signatures.key?(failure.signature)

		@drawing_signatures[failure.signature] = true
		error, *errors = failure.errors
		drawing = error.merge("message" => "#{Quickdraw.utf8(error['message'])} It happened while generating the case’s input, so there’s no counterexample.")
		finding(nil, failure.with(errors: [drawing, *errors]), input: nil, original: nil, shrinks: 0)
	end

	private def finding(choices, failure, input:, original:, shrinks:)
		finding = Quickdraw::Fuzz::Finding.new(
			kind: Quickdraw::Fuzz::Finding.kind(failure),
			key: @key,
			choices:,
			input:,
			original:,
			failure:,
			cases: @cases,
			shrinks:,
		)

		@channel.write([:fuzz_finding, finding])
	end

	# Runs one case in a fork, as a Run whose failure is the crash or hang if
	# it crashed or hung. Nil if it was discarded, or the test didn't get as
	# far as running it.
	private def attempt(prefix)
		pid, channel = fork_test { |writer| Quickdraw::Fuzz::Attempt.new(writer, prefix) }
		limit = test_timeout
		drawn = nil

		loop do
			case receive(channel, pid, limit)
			in :timeout
				return drawn && Quickdraw::Property::Run.new(**drawn, failure: hang(pid, channel))
			in [:drawn, choices, limits, spans, input]
				@inputs[choices] = input
				drawn = { choices:, limits:, spans: }
				limit = @timeout
			in [:ran, failure]
				return Quickdraw::Property::Run.new(**drawn, failure:)
			in [:discarded]
				return nil
			in [:finished, result]
				return drawn && Quickdraw::Property::Run.new(**drawn, failure: (Quickdraw::Property::Failure.new(failures: result["failures"], errors: result["errors"]) if result["errors"].any?))
			in [:hung, _] | nil
				return drawn && Quickdraw::Property::Run.new(**drawn, failure: Quickdraw::Fuzz.failure("Quickdraw::Fuzz::Crash", "The process #{exit_reason(pid)}."))
			end
		end
	ensure
		channel.close
		stop(pid)
	end

	# A Hang where the process's case is, which it writes when sent
	# HANG_SIGNAL (see Fuzz.report_hangs), or nowhere if it can't in time, as
	# when C code holds the GVL. Skips what it wrote before the signal.
	private def hang(pid, channel)
		Process.kill(Quickdraw::Fuzz::HANG_SIGNAL, pid)
		deadline = now + HANG_GRACE

		backtrace = loop do
			case receive(channel, pid, (deadline - now).clamp(0, nil))
			in [:hung, backtrace] then break backtrace
			in nil | :timeout then break []
			in _ then nil
			end
		end

		Quickdraw::Fuzz.failure("Quickdraw::Fuzz::Hang", "A case ran for longer than #{@timeout}s.", backtrace)
	end

	# Forks a process that runs the test, with the block's fuzzer waiting for
	# its first property. Returns its pid and a channel to read what it writes.
	private def fork_test
		channel = Quickdraw::Channel.new(*IO.pipe)

		pid = Process.fork do
			channel.reader.close
			Quickdraw::Fuzz.report_hangs(channel)
			Quickdraw::Fuzz.fuzzer = yield(channel)
			Kernel.srand(@test_seed)
			recorder = Quickdraw::Worker::Recorder.new
			@definition.test_class.new(description: @definition.description, block: @definition.block, runner: recorder).run
			channel.write([:finished, recorder.to_h.slice("failures", "errors")])
		ensure
			# Without at_exit hooks, which are the worker's to run.
			exit!(0)
		end

		channel.writer.close
		[pid, channel]
	end

	# Where each case's choices are written before it runs (see
	# Fuzzer#record). Unlinked, so it goes when the worker does.
	private def open_last_case
		path = File.join(Quickdraw.temporary_directory, "quickdraw-fuzz-#{Process.pid}-#{rand(1 << 64).to_s(36)}")
		file = File.open(path, File::RDWR | File::CREAT | File::EXCL, binmode: true)
		File.delete(path)
		file
	end

	# How many cases the process ran, the last one's stage (see
	# Fuzzer::STAGES), and its choices, or its prefix while replaying them,
	# if it got as far as one.
	private def read_last_case
		cases, stage, size = @last_case.pread(13, 0).unpack("Q>CN")
		[cases, Quickdraw::Fuzz::Fuzzer::STAGES.fetch(stage), @last_case.pread(size, 13).unpack("w*")]
	rescue EOFError
		nil
	end

	# The process's next message; nil once it has exited, even if a process it
	# started holds its pipe open; or :timeout after `limit` seconds.
	private def receive(channel, pid, limit)
		deadline = limit && (now + limit)

		until channel.reader.wait_readable(deadline ? (deadline - now).clamp(0, LIVENESS_INTERVAL) : LIVENESS_INTERVAL)
			return (channel.read if channel.reader.wait_readable(0)) if exited?(pid)
			return :timeout if deadline && now >= deadline
		end

		channel.read
	end

	# Reaps the process if it has exited, keeping its status for exit_reason.
	private def exited?(pid)
		return true if @exits.key?(pid)

		_, status = Process.wait2(pid, Process::WNOHANG)
		@exits[pid] = status if status
		!!status
	rescue Errno::ECHILD
		true
	end

	# Unless it's been reaped, so the pid can't be another process's by now.
	private def stop(pid)
		return if exited?(pid)

		Process.kill(:KILL, pid)
		@exits[pid] = Process.wait2(pid).last
	rescue Errno::ESRCH, Errno::ECHILD
		nil
	end

	private def exit_reason(pid)
		status = (@exits[pid] ||= Process.wait2(pid).last)

		if status.signaled?
			"was killed by SIG#{Signal.signame(status.termsig)}"
		else
			"exited with status #{status.exitstatus}"
		end
	rescue Errno::ECHILD
		"exited"
	end

	private def timed_out
		{ "name" => "Quickdraw::Timeout", "message" => "The test took longer than its #{test_timeout}s timeout before reaching its property.", "backtrace" => [] }
	end

	private def test_timeout
		@definition.timeout || Quickdraw::Config.timeout
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
