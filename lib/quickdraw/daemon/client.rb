# frozen_string_literal: true

# A run's side of a daemon (see Daemon): asks it to run the tests, passes on
# what they print and Ctrl-C, and exits as the run did. It's all a warm run
# waits for besides the tests, so it loads as little as it can.
class Quickdraw::Daemon::Client
	# How long a daemon has to answer a request, in seconds. It answers in well
	# under a millisecond, unless it's stopped or the machine is very busy.
	HANDSHAKE = 0.5

	# How often to check that the daemon is still there, in seconds, while it
	# says nothing.
	LIVENESS = 0.25

	# macOS's fcntl command for a file descriptor's path.
	F_GETPATH = 50

	def initialize(arguments, directory: Quickdraw::Daemon.directory)
		@arguments = arguments
		@directory = directory
	end

	# Exits with the run's status once the daemon has run it. Otherwise returns
	# why not: :absent if there's no daemon, :stale if it was out of date, and
	# has stopped, or :declined if it can't run this now.
	def call
		requests = connect or return :absent
		streams = choose_streams or return :declined
		# Before the request, so the run can't start before they're forwarded.
		forward_signals

		begin
			request(streams)
			requests.write_nonblock("#{File.basename(@request)}\n")
		rescue SystemCallError
			# The daemon stopped meanwhile.
			return restore_signals(:absent)
		end

		restore_signals(wait)
	ensure
		requests&.close
		[@status, *@relays&.keys].compact.each(&:close)
		Quickdraw.remove_tree(@request) if @request
	end

	private def connect
		return unless Quickdraw::Daemon.private?(@directory)

		File.open(File.join(@directory, "requests"), File::WRONLY | File::NONBLOCK)
	rescue Errno::ENOENT, Errno::ENXIO
		nil
	end

	# Where the run reads and writes: a terminal's path, for the daemon's
	# processes to open, so they see a terminal too, or a named pipe this
	# process passes on. Nil if the daemon's processes can't have what this
	# one has: a terminal whose path can't be found, or a stdin that's a file
	# or a pipe, which only the tests should read from.
	private def choose_streams
		@request = File.join(@directory, "#{Process.pid}-#{Random.urandom(4).unpack1('H*')}")

		input = if STDIN.tty? then terminal(STDIN)
		elsif same_file?(STDIN.stat, File.stat(File::NULL)) then File::NULL
		end

		output = STDOUT.tty? ? terminal(STDOUT) : File.join(@request, "out")

		error = if STDERR.tty? then terminal(STDERR)
		# In order, when both go to the same place, by sharing a pipe.
		elsif !STDOUT.tty? && same_file?(STDOUT.stat, STDERR.stat) then output
		else File.join(@request, "err")
		end

		[input, output, error] if input && output && error
	rescue SystemCallError, IOError
		nil
	end

	private def request(streams)
		Dir.mkdir(@request, 0o700)
		@status = pipe(File.join(@request, "status"))
		@relays = streams.drop(1).zip([STDOUT, STDERR]).uniq(&:first).select { |path, _io| path.start_with?("#{@request}/") }.to_h { |path, io| [pipe(path), io] }
		STDOUT.sync = STDERR.sync = true

		fields = [File.basename($PROGRAM_NAME), File.umask.to_s(8), *streams, @arguments.size, *@arguments, *ENV.map { |name, value| "#{name}=#{value}" }]
		File.binwrite(File.join(@request, "request"), fields.map { |field| field.to_s.b }.join("\0"))
	end

	# Open for writing too, so reading never ends, even before the daemon opens it.
	private def pipe(path)
		File.mkfifo(path, 0o600)
		File.open(path, File::RDWR | File::NONBLOCK, binmode: true)
	end

	private def wait
		answers = +""
		@deadline = now + HANDSHAKE

		loop do
			readable, = IO.select([@status, *@relays.keys], nil, nil, @daemon ? LIVENESS : (@deadline - now).clamp(0, nil))
			readable&.each { |io| pass_on(io) unless io.equal?(@status) }

			if readable&.include?(@status)
				data = @status.read_nonblock(4096, exception: false)
				answers << data if String === data

				while (line = answers.slice!(/\A.*\n/))
					answer = answered(line.split)
					return answer if answer
				end
			elsif readable.nil?
				answer = unanswered
				return answer if answer
			end
		end
	end

	private def answered(answer)
		case answer
		in ["busy"] | ["declined"] then :declined
		in ["stale"] then :stale
		in ["accepted", pid]
			@daemon = Integer(pid)
			interrupt if @interrupted
			nil
		in ["running", pid]
			@run = Integer(pid)
			terminate if @terminated
			nil
		in ["exit", status]
			@relays.keys.each { |io| pass_on(io) }
			exit(Integer(status))
		end
	end

	# The daemon has said nothing for a while. Before it takes the request,
	# the run can still start cold.
	private def unanswered
		if @run
			return if alive?(@run) || @status.wait_readable(0)

			abort "Quickdraw’s daemon stopped before the run finished. Run again, or with --no-daemon."
		elsif @daemon
			:absent unless alive?(@daemon)
		elsif withdraw
			:declined
		elsif (requests = connect)
			requests.close
			@deadline = now + HANDSHAKE
			nil
		else
			:absent
		end
	end

	# Whether the daemon hadn't taken the request, and now can't.
	private def withdraw
		File.rename(File.join(@request, "request"), File.join(@request, "withdrawn"))
		true
	rescue Errno::ENOENT
		false
	end

	# If what reads a stream has gone, closing its pipe tells the run, as
	# writing to it would tell a cold one.
	private def pass_on(io)
		while String === (data = io.read_nonblock(65_536, exception: false))
			@relays.fetch(io).write(data)
		end
	rescue Errno::EPIPE
		@relays.delete(io)
		io.close
	end

	# The daemon's processes aren't the terminal's, so Ctrl-C doesn't reach
	# them. The daemon leads their process group.
	private def forward_signals
		@handlers = {
			"INT" => trap("INT") do
				@interrupted = true
				interrupt if @daemon
			end,
			"TERM" => trap("TERM") do
				@terminated = true
				terminate if @run
			end,
		}
	end

	# Returns `answer`, for a run that's about to start cold, unless a signal
	# that came before the daemon took the request stops it too.
	private def restore_signals(answer)
		@handlers.each { |name, handler| trap(name, handler || "DEFAULT") }
		Process.kill("TERM", Process.pid) if @terminated
		raise Interrupt if @interrupted

		answer
	end

	private def interrupt = signal("INT", -@daemon)

	# As TERM stops a cold run: its workers stop once it has gone.
	private def terminate
		signal("TERM", @run)
		exit!(143)
	end

	private def signal(name, pid)
		Process.kill(name, pid)
	rescue Errno::ESRCH, Errno::EPERM
		nil
	end

	private def alive?(pid)
		Process.kill(0, pid)
		true
	rescue Errno::ESRCH
		false
	rescue Errno::EPERM
		true
	end

	private def same_file?(one, other)
		[one.dev, one.ino, one.rdev] == [other.dev, other.ino, other.rdev]
	end

	# The path of the terminal `io` is, or nil if it can't be found.
	private def terminal(io)
		path = if File.exist?("/proc/self/fd")
			File.readlink("/proc/self/fd/#{io.fileno}")
		elsif RUBY_PLATFORM.include?("darwin")
			buffer = "\0".b * 1024
			io.fcntl(F_GETPATH, buffer)
			buffer[/\A[^\0]+/]
		end

		path if path && File.chardev?(path) && File.stat(path).rdev == io.stat.rdev
	rescue SystemCallError
		nil
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
