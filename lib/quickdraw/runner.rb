# frozen_string_literal: true

require "json"
require "io/console"

class Quickdraw::Runner
	module Message
		Fetch = "\x01"
		Work = "\x02"
		Stop = "\x03"
		Stopping = "\x04"
	end

	def initialize(backtrace: false, processes:, threads:, files:, seed:)
		@backtrace = backtrace
		@processes = processes
		@threads = threads
		@seed = seed
		@random = Random.new(seed)
		@files = files.shuffle(random: @random)
		@tests = []

		@mutex = Mutex.new
		@cursor = 0

		@cluster = Quickdraw::Cluster.new
		@batch = nil

		@failures = Quickdraw::ConcurrentArray.new
		@errors = Quickdraw::ConcurrentArray.new
		@successes = Quickdraw::ConcurrentInteger.new
	end

	def call
		load_tests

		if @processes > 1
			fork_processes
			@cluster.wait
		else
			@tests.each do |(context, description, skip, block)|
				context.new(description:, skip:, block:).run(self)
			end
		end

		puts

		@errors.each do |error|
			puts

			puts "\e[4m#{error['location'][0]}:#{error['location'][1]} #{error['description']}\e[0m"
			puts "\e[3m  unexpected \e[1m#{error['name']}: #{error['message']}\e[0m"
			error["backtrace"]
				.take_while { |it| @backtrace || !it.include?("Quickdraw::Runner") }
				.map { |it| it.gsub(":in `", " in `") }
				.each do |line|
					puts line
				end
		end

		@failures.each do |failure|
			puts

			[
				"\e[1m#{(failure['class_name'])}\e[0m",
				"\e[4m#{failure['test_path']}:#{failure['test_line']}\e[0m",
				"\e[1m#{(failure['description'])}\e[0m",
				"\e[4m#{failure['path']}:#{failure['line']}\e[0m",
			].each_with_index do |line, i|
				puts "#{'  ' * i}#{line}"
			end

			puts
			puts "\e[3m#{(failure['message'])}\e[0m"
		end

		puts

		puts "Passed: #{@successes.value} | Failed: #{@failures.size} | Errors: #{@errors.size}"

		exit(1) if @failures.any? || @errors.any?
	end

	def load_tests
		number_of_files = @files.size
		i = 0

		while i < number_of_files
			file_path = @files[i]

			Class.new(Quickdraw::Test) do
				set_temporary_name "(#{file_path})" if respond_to?(:set_temporary_name)
				class_eval(File.read(file_path), file_path, 1)
			end

			i += 1
		end

		@tests.shuffle!(random: @random)
		@tests.freeze
		# Try to break up the tests into at least 20 batches per core.
		@batch = (@tests.size / @processes / 20).clamp(1, 500)
	end

	def fork_processes
		Quickdraw::Config.before_forking_callbacks.each(&:call)

		@processes.times do
			worker = @cluster.fork { |it| work(it) }
			supervise(worker)
		end
	end

	def <<(test)
		@tests << test
	end

	def success!(description)
		@successes.increment
	end

	def failure!(failure)
		@failures << failure
	end

	def error!(error)
		@errors << error
	end

	private

	def work(socket)
		Quickdraw::Config.after_forking_callbacks.each(&:call)

		batch = @batch
		queue = Thread::SizedQueue.new(batch)
		tests = @tests
		tests_size = @tests.size

		threads = @threads.times.map do |i|
			Thread.new do
				while true
					index = queue.pop
					break if index == :stop
					context, description, skip, block = tests[index]
					context.new(description:, skip:, block:).run(self)
				end
			end
		end

		while true
			socket.write Message::Fetch

			case socket.read(1)
			when nil, Message::Stop
				threads.each { queue.push(:stop) }
				threads.each(&:join)
				socket.write Message::Stopping
				socket.write JSON.generate({
					errors: @errors.to_a,
					failures: @failures.to_a,
					successes: @successes.value,
				})
				break
			when Message::Work
				cursor = socket.read(4).unpack1("L<")
				stop = [tests_size, cursor + batch].min

				while cursor < stop
					queue.push(cursor)
					cursor += 1
				end
			else
				raise "Unhandled message: #{message}"
			end
		end
	end

	def supervise(worker)
		socket = worker.socket
		mutex = @mutex
		batch = @batch
		progress = 0

		console = IO.console

		if console
			console_width = IO.console.winsize[1]
			bar_width = console_width - 6
		end

		Thread.new do
			while true
				message = socket.read(1)
				tests_length = @tests.size

				case message
				when nil
					break
				when Message::Fetch
					mutex.synchronize do
						if @cursor < tests_length
							socket.write Message::Work
							socket.write [@cursor].pack("L<")
							@cursor += batch
						else
							socket.write Message::Stop
						end
					end

					if console
						progress = @cursor >= tests_length ? 100.0 : (@cursor * 100.0 / tests_length)
						print "\r\e[K#{'█' * (progress * bar_width / 100.0).floor}#{'░' * (bar_width - (progress * bar_width / 100.0).floor)} #{progress.round}%"
					end
				when Message::Stopping
					results = JSON.parse(socket.read)
					@failures.concat(results["failures"])
					@errors.concat(results["errors"])
					@successes.increment(results["successes"])
				else
					raise "Unhandled message: #{message}"
				end
			end
		end
	end

	def enable_yjit
		RubyVM::YJIT.enable
	end

	def yjit_supported?
		Quickdraw::Platform.yjit_supported?
	end
end
