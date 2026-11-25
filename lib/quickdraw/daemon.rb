# frozen_string_literal: true

# Lets ordinary runs start warm. A run that starts cold leaves a daemon behind
# (see Server), which keeps config booted in loaders, as watch mode does (see
# WarmLoaders). The next run asks the daemon to run its tests (see Client), in
# a fork that's ready as soon as it's asked, and only passes on what it prints
# and how it exits. Whenever the daemon can't do exactly what a cold start
# would, the run starts cold, as it would without one.
#
# A project's daemon is found by its directory, which holds:
#
#   lock        locked by the daemon while it lives
#   pid         its process ID, which stops it when sent TERM
#   requests    a named pipe, on which a run writes the name of its request
#   NAME/       a request, made by the run:
#     request   what to run, fields separated by NUL: the program's name, its
#               umask in octal, the paths of its stdin, stdout and stderr, the
#               number of arguments, the arguments, then the environment as
#               NAME=value. The daemon renames it to `accepted` to take it, or
#               the run to `withdrawn`.
#     status    a named pipe for the daemon's answers, a line each: `busy`,
#               `stale` (it's out of date, and stopping), or `accepted PID`,
#               then `running PID` from the fork running the tests, then
#               `exit STATUS`, or `declined` for what only a cold start can do
#     out, err  named pipes for what the run prints, unless it's a terminal,
#               which the daemon's processes open themselves
#
# Named pipes rather than a socket, since loaders fork from the daemon, and
# tests would see the socket library.
module Quickdraw::Daemon
	extend self

	autoload :Client, "quickdraw/daemon/client"
	autoload :Server, "quickdraw/daemon/server"

	# Set to 0, runs always start cold, as with --no-daemon.
	VARIABLE = "QUICKDRAW_DAEMON"

	# Environment variables a run can differ from its daemon in, which shells
	# and terminals change from one command to the next. Config booted with
	# the daemon's, and tests see the run's. Any other difference means a new
	# daemon.
	VOLATILE = Quickdraw.deep_freeze(["_", "SHLVL", "OLDPWD", "COLUMNS", "LINES", "SEED", "WINDOWID", "TERM_SESSION_ID", "ITERM_SESSION_ID", "TMUX_PANE", "SSH_TTY", "SSH_CLIENT", "SSH_CONNECTION", "GPG_TTY", "SECURITYSESSIONID"])

	# Quickdraw's own, which stay the daemon's.
	OWN = Quickdraw.deep_freeze(["QUICKDRAW_DEBUGGING", "QUICKDRAW_DAEMON", "QUICKDRAW_DAEMON_IDLE"])

	# fcntl's F_GETFL and F_SETFL, without its library, which tests would see.
	GET_FLAGS = 3
	SET_FLAGS = 4

	# Not in CI, where no run follows to use it.
	def enabled?(arguments)
		Process.respond_to?(:fork) && !(ENV[VARIABLE] in "0" | "false" | "off") && !arguments.include?("--no-daemon") && !Quickdraw::Reporters.ci?
	end

	# Runs `arguments` in this project's daemon, and exits as the run did.
	# Returns if it can't, for the run to start cold.
	def run(arguments)
		@answer = Client.new(arguments).call if enabled?(arguments)
	end

	# Whether a run that starts cold should leave a daemon for the next: there
	# was none to ask, or it was out of date.
	def wanted?
		@answer in :absent | :stale
	end

	# One for each project, Ruby and copy of Quickdraw.
	def directory(root = Quickdraw::ROOT)
		key = Quickdraw.stable_hash([root, Quickdraw::LIB, RUBY_DESCRIPTION].join("\0")).to_s(36)
		File.join(Quickdraw.temporary_directory, "quickdraw-daemon-#{Process.uid}-#{key}")
	end

	# Whether `directory` is this user's alone, and not a link to somewhere
	# else, since /tmp is shared.
	def private?(directory)
		stat = File.lstat(directory)
		stat.directory? && stat.owned? && stat.mode & 0o077 == 0
	rescue SystemCallError
		false
	end

	# What a daemon and the runs it serves must agree on, as bytes, since a
	# value that isn't valid in the locale's encoding (UTF-8 when it's C)
	# compares by its encoding too.
	def environment(variables)
		variables.except(*VOLATILE, *OWN).to_h { |name, value| [name.b, value.b] }
	end

	# In a worker of a daemon's run: takes on what tests can see of the
	# process that asked for the run, which the loader it forked from doesn't
	# have: its streams, its arguments, and the environment variables that can
	# differ (see WarmLoaders#invocation=).
	def adopt(invocation)
		streams, arguments, variables = invocation
		redirect(streams)
		ARGV.replace(arguments)
		VOLATILE.each { |name| variables.key?(name) ? ENV[name] = variables[name] : ENV.delete(name) }
	end

	# Points this process's stdin, stdout and stderr at the paths in `streams`,
	# a run's: each a terminal, a named pipe its Client reads, or nil for
	# nothing, as is one that can't be opened, since the run has gone.
	def redirect(streams)
		input, output, error = streams

		begin
			STDIN.reopen(input || File::NULL)
		rescue SystemCallError
			STDIN.reopen(File::NULL)
		end

		write_to(STDOUT, output)
		write_to(STDERR, error)
	end

	# Opened without waiting for a reader, then set to wait when writing, as
	# programs that tests run expect.
	private def write_to(io, path)
		file = File.open(path || File::NULL, File::WRONLY | File::NONBLOCK | File::NOCTTY)
		file.fcntl(SET_FLAGS, file.fcntl(GET_FLAGS) & ~File::NONBLOCK)
		io.reopen(file)
	rescue SystemCallError
		io.reopen(File::NULL, "w")
	ensure
		file&.close
	end
end
