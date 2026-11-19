# frozen_string_literal: true

# Runs in a forked process alongside user code, so it must only use core Ruby.
#
# Everything sent to the coordinator is converted to plain strings, numbers,
# arrays and hashes, since user objects may not survive Marshal.
class Quickdraw::Worker
	ANONYMOUS_MODULE = /#<Module:0x\h+>::/

	class Recorder
		def initialize
			@assertions = 0
			@failures = []
			@errors = []
		end

		def success!(_description)
			@assertions += 1
		end

		def failure!(failure)
			@assertions += 1
			@failures << failure
		end

		def error!(error)
			@errors << error
		end

		def to_h
			{ "assertions" => @assertions, "failures" => @failures, "errors" => @errors }
		end
	end

	def initialize(channel, test_files)
		@channel = channel
		@test_files = test_files
		@files = {}
	end

	def call
		@channel.write([:ready, Process.pid])

		while (message = @channel.read)
			case message
			in [:load, path]
				@channel.write(load(path))
			in [:run, path, indices]
				@channel.write([:started])
				tests = @files.fetch(path)
				indices.each { |index| @channel.write([:result, index, run(*tests[index])]) }
				@channel.write([:ready, Process.pid])
			in [:stop]
				break
			end
		end
	end

	private def load(path)
		started_at = now
		tests = Quickdraw.collect_tests(path, @test_files) { Kernel.load(path, Module.new) }
		@files[path] = tests

		[:loaded, path, tests.map { |test| describe(test) }, now - started_at]
	rescue Exception => error
		[:load_failed, path, Quickdraw.serialize_error(error)]
	end

	private def describe((test_class, description, block))
		{
			"description" => description&.then { |it| Quickdraw.plain_string(it).gsub(ANONYMOUS_MODULE, "") },
			"line" => block.source_location[1],
			"class_name" => test_class.name&.gsub(ANONYMOUS_MODULE, ""),
		}
	end

	private def run(test_class, description, block)
		recorder = Recorder.new
		started_at = now
		test_class.new(description:, block:, runner: recorder).run
		recorder.to_h.merge!("duration" => now - started_at)
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
