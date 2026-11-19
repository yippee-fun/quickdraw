# frozen_string_literal: true

class Quickdraw::CLI
	DEFAULT_PATTERN = "./**/*.test.rb"

	LISTENER = <<~RUBY
		require "listen"
		$stdout.sync = true
		Listen.to(".", wait_for_delay: 0.01) { puts "changed" }.start
		sleep
	RUBY

	def initialize(args)
		@args = args
	end

	def call
		# optparse, etc and anything else needed to parse options load in a
		# throwaway process so they don’t leak into the processes that run tests.
		options = Quickdraw.isolate { parse }

		if options[:watch]
			watch(options)
		else
			exit(run(options) ? 0 : 1)
		end
	end

	private def parse
		require "optparse"

		options = { backtrace: false, processes: nil, watch: false, seed: nil, efficiency: false }

		OptionParser.new do |parser|
			parser.banner = "Usage: quickdraw [options] [paths or globs]"

			parser.on("-h", "--help", "Prints this help") do
				puts parser
				exit
			end

			parser.on("-b", "--backtrace", "Show backtrace frames inside Quickdraw") do
				options[:backtrace] = true
			end

			parser.on("-p N", "--processes N", Integer, "Number of worker processes") do |it|
				options[:processes] = it
			end

			parser.on("-m", "--max", "Use all available CPU cores") do
				options[:max] = true
			end

			parser.on("-e", "--efficiency", "Use efficiency cores (Apple M-series Macs only)") do
				options[:efficiency] = true
			end

			parser.on("-w", "--watch", "Watch for changes") do
				options[:watch] = true
			end

			parser.on("-s N", "--seed N", Integer, "Seed for randomization") do |it|
				options[:seed] = it
			end
		end.parse!(@args)

		if [options[:processes], options[:max], options[:efficiency]].count(&:itself) > 1
			abort "Use only one of --processes, --max and --efficiency."
		end

		if options[:efficiency] && !Quickdraw::Platform.m_series?
			abort "Efficiency cores are only available on M-series Macs."
		end

		if options[:watch] && !Quickdraw::Platform.supports_forking?
			abort "Watch mode needs fork, which this platform doesn’t support."
		end

		options[:processes] = if !Quickdraw::Platform.supports_forking?
			1
		elsif options[:max]
			Quickdraw::Platform.cpu_cores
		elsif options[:efficiency]
			Quickdraw::Platform.efficiency_cores
		else
			options[:processes] || Quickdraw::Platform.non_blocking_cores
		end

		abort "--processes must be at least 1." if options[:processes] < 1

		options[:seed] ||= Random.new_seed % 100_000
		options[:patterns] = @args.empty? ? [DEFAULT_PATTERN] : @args.dup
		options
	end

	private def run(options)
		system("taskpolicy", "-b", "-p", Process.pid.to_s) if options[:efficiency]

		Quickdraw::Coordinator.new(
			files: Dir.glob(options[:patterns]).uniq,
			processes: options[:processes],
			seed: options[:seed],
			reporter: Quickdraw::Reporter.new(backtrace: options[:backtrace]),
		).call
	end

	private def watch(options)
		listener = IO.popen([RbConfig.ruby, "-e", LISTENER])

		run_in_fork(options)
		listener.each_line { run_in_fork(options) }
		listener.close
		abort "The file watcher stopped (#{$?})." unless $?.success?
	ensure
		Process.kill("TERM", listener.pid) if listener && !listener.closed?
	end

	private def run_in_fork(options)
		pid = Process.fork do
			print "\e[H\e[2J"
			exit(run(options) ? 0 : 1)
		end

		Process.wait(pid)
	end
end
