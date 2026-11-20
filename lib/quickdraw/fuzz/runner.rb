# frozen_string_literal: true

# Drives fuzzing for `quickdraw fuzz`: boots config and starts workers (see
# WorkerPool), then has every worker fuzz a test at once, each with a seed of
# its own (see Session). They share the test's corpus as they go.
class Quickdraw::Fuzz::Runner
	def initialize(test_files, processes:, seed:)
		@pool = Quickdraw::WorkerPool.new(test_files, processes:, seed:)
	end

	# See WorkerPool#start.
	def start = @pool.start

	def stop = @pool.stop

	# The tests in the file at `path`, as workers describe them, loading it in
	# every worker. Nil if it failed to load in all of them.
	def load(path)
		@pool.in_slots do |slot|
			slot.load(path)
		rescue Quickdraw::WorkerPool::Gone
			nil
		end.compact.first
	end

	# Fuzzes the test at `index` in the file at `path` in every worker that
	# loaded it, yielding the workers' messages as they arrive (see Session).
	# Returns each worker's outcome, ["unloaded"] if the file failed to load
	# in it, or ["lost"] if it exited.
	def call(path, index, seconds:, timeout:, seed:, explicit:)
		messages = Thread::Queue.new

		threads = @pool.slots.each_with_index.map do |slot, number|
			Thread.new do
				next ["unloaded"] unless slot.load(path)

				slot.write([:fuzz, path, index, { seconds:, timeout:, seed: seed + number, explicit: }])

				loop do
					message = slot.read
					break message.last if message.first == :fuzzed

					messages << message
				end
			rescue Quickdraw::WorkerPool::Gone
				["lost"]
			ensure
				messages << :done
			end
		end

		done = 0

		while done < threads.size
			case messages.pop
			in :done then done += 1
			in message then yield message
			end
		end

		threads.map(&:value)
	end
end
