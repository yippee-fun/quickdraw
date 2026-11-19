# frozen_string_literal: true

# Schedules tests across workers and feeds their results to a reporter. Never
# loads user code.
#
# Workers load files lazily. Batches from a file start at one test and double
# while the file's tests stay under the batch budget, so a slow file never
# hands all of its tests to one worker. Once every file is loaded, idle workers
# steal from the file with the most estimated time left, loading it themselves
# when that's worth more than the cost of loading.
class Quickdraw::Coordinator
	BATCH_BUDGET = 0.02

	class TestFile
		def initialize(path, display_path, tests, load_duration, random)
			@path = path
			@display_path = display_path
			@tests = tests
			@load_duration = load_duration
			@pending = Array.new(tests.size) { |index| index }.shuffle(random:)
			@batch_size = 1
			@total_duration = 0.0
			@completed = 0
		end

		attr_reader :path, :display_path, :tests, :pending, :load_duration

		def next_batch
			average = average_duration
			size = average ? [@batch_size, (BATCH_BUDGET / [average, 1e-9].max).floor].min : 1
			size = size.clamp(1, @pending.size)
			@batch_size = size * 2
			@pending.shift(size)
		end

		def record(duration)
			@total_duration += duration
			@completed += 1
		end

		def average_duration
			@total_duration / @completed if @completed > 0
		end

		def estimated_pending_time
			average = average_duration
			average * @pending.size if average
		end
	end

	class Worker
		def initialize(channel)
			@channel = channel
			@loaded = {}
			@loading = nil
			@batch = nil
			@started = false
			@idle = false
			@pid = nil
		end

		attr_reader :channel, :loaded
		attr_accessor :loading, :batch, :started, :idle, :pid

		# A child process the worker forked can hold its pipe open after it dies,
		# so EOF alone can't be relied on.
		def alive?
			return true unless @pid

			Process.kill(0, @pid)
			true
		rescue Errno::ESRCH
			false
		end
	end

	def initialize(files:, processes:, seed:, reporter:)
		@seed = seed
		@processes = processes
		@reporter = reporter
		@unloaded = files.shuffle(random: Random.new(seed)).map { |path| [File.expand_path(path), path] }
		@display_paths = @unloaded.to_h
		@files = {}
	end

	def call
		pairs = Array.new(@processes) { Quickdraw::Channel.pair }
		coordinator_channels = pairs.map(&:first)
		worker_channels = pairs.map(&:last)

		test_files = @unloaded.map(&:first)

		if Process.respond_to?(:fork)
			loader = Process.fork do
				coordinator_channels.each(&:close)
				exit(Quickdraw::Loader.new(worker_channels, test_files).call)
			end
			worker_channels.each(&:close)
		else
			Quickdraw::Loader.new(worker_channels, test_files).call_in_thread
		end

		@workers = coordinator_channels.to_h { |channel| [channel.reader, Worker.new(channel)] }
		@reporter.start(processes: @processes, seed: @seed)

		until @workers.empty?
			readable, = IO.select(@workers.keys, nil, nil, 1)

			if readable
				readable.each do |io|
					worker = @workers[io]
					handle(worker, worker.channel.read) if worker
				end
			else
				@workers.values.reject(&:alive?).each { |worker| crashed(worker) }
			end

			dispatch
		end

		processes_failed = loader ? !Process.wait2(loader).last.success? : false

		@reporter.finish(
			not_run: @unloaded.size + @files.each_value.sum { |file| file.pending.size },
			processes_failed:,
		)
	end

	private def handle(worker, message)
		case message
		in nil
			crashed(worker)
		in [:ready, pid]
			worker.pid = pid
			worker.idle = true
		in [:started]
			worker.started = true
		in [:loaded, path, tests, load_duration]
			loaded(worker, path, tests, load_duration)
		in [:load_failed, path, error]
			worker.loading = nil
			worker.loaded[path] = false
			worker.idle = true
			@reporter.load_failed(display_path(path), error) unless @files.key?(path)
		in [:result, index, result]
			record(worker, index, result)
		end
	end

	private def loaded(worker, path, tests, load_duration)
		worker.loading = nil
		worker.loaded[path] = true
		worker.idle = true

		if (file = @files[path])
			unless file.tests == tests
				raise "#{file.display_path} defined different tests when loaded in a second worker."
			end
		else
			display_path = display_path(path)
			random = Random.new(@seed ^ display_path.sum(64))
			@files[path] = TestFile.new(path, display_path, tests, load_duration, random)
		end
	end

	private def record(worker, index, result)
		file, indices = worker.batch
		expected = indices.shift
		raise "Expected a result for test #{expected} but got #{index}." unless expected == index

		worker.batch = nil if indices.empty?
		file.record(result["duration"])
		@reporter.result(file.display_path, file.tests[index], result)
	end

	private def crashed(worker)
		@workers.delete(worker.channel.reader)
		worker.channel.close

		crash = {
			"name" => "Quickdraw::WorkerCrashed",
			"message" => "The worker process exited unexpectedly.",
			"backtrace" => [],
		}

		if (path = worker.loading)
			@reporter.load_failed(display_path(path), crash) unless @files.key?(path)
		elsif (batch = worker.batch)
			file, indices = batch

			if worker.started
				index, *rest = indices
				file.pending.unshift(*rest)
				@reporter.result(file.display_path, file.tests[index], {
					"assertions" => 0, "failures" => [], "errors" => [crash], "duration" => nil
				})
			else
				file.pending.unshift(*indices)
			end
		end
	end

	private def dispatch
		idle = @workers.each_value.select(&:idle)
		all_idle = idle.size == @workers.size

		idle.each do |worker|
			if (file = own_file(worker))
				run_batch(worker, file)
			elsif (path, = @unloaded.shift)
				load(worker, path)
			elsif (file = file_to_steal(worker, all_idle))
				load(worker, file.path)
			end
		end

		return unless all_idle && @workers.each_value.all?(&:idle)

		@workers.each_value { |worker| worker.channel.write([:stop]) }
		@workers.clear
	end

	private def own_file(worker)
		worker.loaded
			.filter_map { |path, loaded| @files.fetch(path) if loaded }
			.select { |file| file.pending.any? }
			.max_by { |file| file.pending.size }
	end

	# When every worker is idle, nothing else will pick up the work, so steal regardless of cost.
	private def file_to_steal(worker, all_idle)
		candidates = @files.each_value.reject { |file| worker.loaded.key?(file.path) || file.pending.empty? }

		unless all_idle
			candidates.select! do |file|
				estimate = file.estimated_pending_time
				estimate && estimate > file.load_duration * 2
			end
		end

		candidates.max_by { |file| file.estimated_pending_time || 0 }
	end

	private def run_batch(worker, file)
		indices = file.next_batch
		worker.batch = [file, indices.dup]
		worker.started = false
		worker.idle = false
		crashed(worker) unless worker.channel.write([:run, file.path, indices])
	end

	private def load(worker, path)
		worker.loading = path
		worker.idle = false
		crashed(worker) unless worker.channel.write([:load, path])
	end

	private def display_path(path)
		@display_paths.fetch(path)
	end
end
