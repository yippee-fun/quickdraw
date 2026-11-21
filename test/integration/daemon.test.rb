# frozen_string_literal: true

require_relative "../support/integration"

class DaemonTest < Quickdraw::Test
	include Integration
	include Integration::Daemons

	# Config that counts the times it boots, so a run that didn't add to it
	# started warm. A cold run boots it, and so does the daemon it leaves.
	BOOT_COUNTER = %(File.write("boots.log", "x", mode: "a")\n)

	PASSING = "class A < Quickdraw::Test; test('a') { assert true }; end\n"

	def setup
		super
		skip "The daemon needs fork" unless Process.respond_to?(:fork)
	end

	def boots(project) = File.read(File.join(project.directory, "boots.log")).size

	def alive?(pid)
		Process.kill(0, pid)
		true
	rescue Errno::ESRCH
		false
	end

	# A project whose daemon stops when the test ends.
	def daemon_project(files) = with_daemon(project(files))

	test "runs start from the daemon the first left, with config booted", timeout: 40 do
		project = daemon_project("config/quickdraw.rb" => BOOT_COUNTER, "test/a.test.rb" => PASSING)

		cold = warm(project)
		first = daemon_run(project, "-p", "1")
		second = daemon_run(project, "-p", "1")

		assert cold.success?
		assert(first.success?) { first.output }
		assert second.success?
		assert_equal [cold, first, second].map { |result| result.summary.sub(/ · [\d.]+s\z/, "") }.uniq, ["1 test · 1 assertion"]
		assert_equal boots(project), 2
	end

	test "keeps one loader for a project with no config", timeout: 40 do
		project = daemon_project("test/a.test.rb" => "class A < Quickdraw::Test; test('a') { File.write('loaders.log', \"\#{Process.ppid}\\n\", mode: 'a'); assert true }; end\n")

		warm(project)
		daemon_run(project, "-p", "1")
		daemon_run(project, "-p", "1")
		cold, *warm = File.readlines(File.join(project.directory, "loaders.log"))

		assert_equal warm.uniq.size, 1
		refute_equal warm.first, cold
	end

	test "tests see the arguments and seed of the run, not the daemon's", timeout: 40 do
		project = daemon_project(
			"config/quickdraw.rb" => BOOT_COUNTER,
			"test/a.test.rb" => "class A < Quickdraw::Test; test('a') { File.write('seen.log', [ENV['SEED'], *ARGV].join(' ')); assert true }; end\n",
		)

		warm(project, env: { "SEED" => "1" })
		result = daemon_run(project, "-p", "1", "--name", "a", env: { "SEED" => "2" })

		assert(result.success?) { result.output }
		assert_equal File.read(File.join(project.directory, "seen.log")), "2 -p 1 --name a"
		assert_equal boots(project), 2
	end

	test "a run with a stdin that tests could read starts cold", timeout: 40 do
		project = daemon_project("config/quickdraw.rb" => BOOT_COUNTER, "test/a.test.rb" => PASSING)

		warm(project)
		result = project.run("-p", "1", env: { "QUICKDRAW_DAEMON" => nil })

		assert(result.success?) { result.output }
		assert_equal boots(project), 3
	end

	test "runs whose config reports flakes start cold, since only a loader that exits reports them", timeout: 40 do
		project = daemon_project("config/quickdraw.rb" => "#{BOOT_COUNTER}Quickdraw.configure { |config| config.on_flaky { |flake| nil } }\n", "test/a.test.rb" => PASSING)

		cold = warm(project)
		result = daemon_run(project, "-p", "1")

		assert cold.success?
		assert(result.success?) { result.output }
		assert_equal Integration.summaries(result.stdout).size, 1
		assert_equal boots(project), 4
	end

	test "a warm run prints and exits as a cold one does", timeout: 40 do
		project = daemon_project(
			"config/quickdraw.rb" => BOOT_COUNTER,
			"test/a.test.rb" => <<~RUBY,
				class A < Quickdraw::Test
					test("fails") { assert_equal 1, 2 }
					test("warns") { warn "from the test"; assert true }
				end
			RUBY
		)

		cold = warm(project, "--seed", "1")
		warm = daemon_run(project, "-p", "1", "--seed", "1")

		assert_equal warm.exit_status, 1
		assert_equal cold.exit_status, 1
		assert_equal warm.stdout.gsub(/[\d.]+(?:μs|ms|s)/, ""), cold.stdout.gsub(/[\d.]+(?:μs|ms|s)/, "")
		assert_equal warm.stderr, cold.stderr
		assert_equal boots(project), 2
	end

	test "what tests print without capture reaches the run", timeout: 40 do
		project = daemon_project(
			"config/quickdraw.rb" => BOOT_COUNTER,
			"test/a.test.rb" => "class A < Quickdraw::Test; test('a') { puts 'printed by the test'; system('echo printed by a program'); assert true }; end\n",
		)

		warm(project)
		result = daemon_run(project, "-p", "1", "--no-capture")

		assert(result.success?) { result.output }
		assert_includes result.stdout, "printed by the test"
		assert_includes result.stdout, "printed by a program"
		assert_equal boots(project), 2
	end

	test "a usage error comes from the daemon as it would cold", timeout: 40 do
		project = daemon_project("config/quickdraw.rb" => BOOT_COUNTER, "test/a.test.rb" => PASSING)

		warm(project)
		result = daemon_run(project, "--nope")

		assert_equal result.exit_status, 2
		assert_includes result.stderr, "--nope"
		assert_equal boots(project), 2
	end

	test "boots again when a file config loaded changes", timeout: 40 do
		project = daemon_project(
			"config/quickdraw.rb" => "#{BOOT_COUNTER}require_relative '../lib/answer'\n",
			"lib/answer.rb" => "ANSWER = 1\n",
			"test/a.test.rb" => "class A < Quickdraw::Test; test('a') { assert_equal ANSWER, 2 }; end\n",
		)

		assert_equal warm(project).exit_status, 1
		assert_equal daemon_run(project, "-p", "1").exit_status, 1
		assert_equal boots(project), 2

		project.write("lib/answer.rb" => "ANSWER = 2\n")
		result = daemon_run(project, "-p", "1")

		assert(result.success?) { result.output }
		assert_equal boots(project), 3
		assert daemon_run(project, "-p", "1").success?
		assert_equal boots(project), 3
	end

	test "reloads a changed file with config's reloader, rather than booting again", timeout: 40 do
		project = daemon_project(
			"config/quickdraw.rb" => <<~RUBY,
				#{BOOT_COUNTER}require_relative "../lib/answer"
				Quickdraw.configure { |config| config.reloader { |paths| paths.each { |path| load path }; true } }
			RUBY
			"lib/answer.rb" => "def answer = 1\n",
			"test/a.test.rb" => "class A < Quickdraw::Test; test('a') { assert_equal answer, 2 }; end\n",
		)

		assert_equal warm(project).exit_status, 1

		project.write("lib/answer.rb" => "def answer = 2\n")
		result = daemon_run(project, "-p", "1")

		assert(result.success?) { result.output }
		assert_equal boots(project), 2
	end

	test "boots again when config changes, or gains a file", timeout: 40 do
		project = daemon_project("config/quickdraw.rb" => BOOT_COUNTER, "test/a.test.rb" => PASSING)

		warm(project)
		project.write("config/quickdraw.rb" => "#{BOOT_COUNTER}# Changed\n")
		daemon_run(project, "-p", "1")

		assert_equal boots(project), 3

		project.write("config/settings.yml" => "a: 1\n")
		daemon_run(project, "-p", "1")

		assert_equal boots(project), 4
	end

	test "a run in a different environment replaces the daemon", timeout: 40 do
		project = daemon_project("config/quickdraw.rb" => BOOT_COUNTER, "test/a.test.rb" => "class A < Quickdraw::Test; test('a') { assert_equal ENV['COLOUR'], 'red' }; end\n")

		assert_equal warm(project).exit_status, 1
		first = daemon_pid(project)
		result = daemon_run(project, "-p", "1", env: { "COLOUR" => "red" })

		assert(result.success?) { result.output }
		wait_until { daemon?(project) && daemon_pid(project) != first }
		assert daemon_run(project, "-p", "1", env: { "COLOUR" => "red" }).success?
		assert_equal boots(project), 4
		refute alive?(first)
	end

	test "runs the daemon can't serve start cold", timeout: 40 do
		project = daemon_project("config/quickdraw.rb" => BOOT_COUNTER, "test/a.test.rb" => PASSING)

		warm(project)
		daemon = daemon_pid(project)
		json = daemon_run(project, "-p", "1", "--format", "json")
		coverage = daemon_run(project, "-p", "1", "--coverage")
		opted_out = daemon_run(project, "-p", "1", "--no-daemon")
		command = daemon_run(project, "counterpart", "lib/a.rb")

		assert(json.events.any?) { json.output }
		assert(coverage.success?) { coverage.output }
		assert opted_out.success?
		assert_includes command.output, "lib/a.rb"
		assert_equal boots(project), 5
		assert_equal daemon_pid(project), daemon
	end

	test "leaves no daemon when turned off, or in CI", timeout: 40 do
		project = daemon_project("test/a.test.rb" => PASSING)

		daemon_run(project, "-p", "1", "--no-daemon")
		project.run("-p", "1")
		daemon_run(project, "-p", "1", env: { "CI" => "true" })
		# One would have started by now.
		sleep 0.3

		refute Dir.exist?(daemon_directory(project))
	end

	test "a run while the daemon is busy starts cold", timeout: 40 do
		project = daemon_project(
			"config/quickdraw.rb" => BOOT_COUNTER,
			"test/a.test.rb" => PASSING,
			"test/slow.test.rb" => <<~RUBY,
				class Slow < Quickdraw::Test
					test("slow") do
						File.write("started.log", "x")
						sleep 0.01 until File.exist?("finish.log")
						assert true
					end
				end
			RUBY
		)

		daemon_run(project, "-p", "1", "test/a.test.rb")
		wait_until { daemon?(project) }
		slow = Thread.new { daemon_run(project, "-p", "1", "test/slow.test.rb", timeout: 30) }
		wait_until { File.exist?(File.join(project.directory, "started.log")) }
		quick = daemon_run(project, "-p", "1", "test/a.test.rb")
		project.write("finish.log" => "x")

		assert(quick.success?) { quick.output }
		assert(slow.value.success?) { slow.value.output }
		assert_equal boots(project), 3
	end

	test "Ctrl-C reaches a warm run", timeout: 40 do
		project = daemon_project(
			"config/quickdraw.rb" => BOOT_COUNTER,
			"test/a.test.rb" => PASSING,
			"test/slow.test.rb" => <<~RUBY,
				class Slow < Quickdraw::Test
					test("slow") do
						puts "started"
						sleep 20
					end
				end
			RUBY
		)

		daemon_run(project, "-p", "1", "test/a.test.rb")
		wait_until { daemon?(project) }
		result = daemon_run(project, "-p", "1", "--no-capture", "test/slow.test.rb", timeout: 15, interrupt_when: /started/)

		assert_equal result.exit_status, 130
		assert_includes result.output, "INTERRUPTED"
		assert daemon_run(project, "-p", "1", "test/a.test.rb").success?
		assert_equal boots(project), 2
	end

	test "stops by itself once it's been idle", timeout: 40 do
		project = daemon_project("config/quickdraw.rb" => BOOT_COUNTER, "test/a.test.rb" => PASSING)

		daemon_run(project, "-p", "1", env: { "QUICKDRAW_DAEMON_IDLE" => "0.5" })
		wait_until { daemon?(project) }
		pid = daemon_pid(project)

		wait_until { !Dir.exist?(daemon_directory(project)) }
		wait_until { !alive?(pid) }
	end

	test "a run after the daemon was killed starts cold, and leaves a new one", timeout: 40 do
		project = daemon_project("config/quickdraw.rb" => BOOT_COUNTER, "test/a.test.rb" => PASSING)

		warm(project)
		killed = daemon_pid(project)
		Process.kill("KILL", killed)
		wait_until { !alive?(killed) }
		result = daemon_run(project, "-p", "1")

		assert(result.success?) { result.output }
		wait_until { daemon?(project) && daemon_pid(project) != killed }
		assert daemon_run(project, "-p", "1").success?
		assert_equal boots(project), 4
	end

	test "a warm run on a terminal writes to it", timeout: 40 do
		skip "Needs a terminal" unless terminal?

		project = daemon_project("config/quickdraw.rb" => BOOT_COUNTER, "test/a.test.rb" => PASSING)

		warm(project, env: { "NO_COLOR" => nil })
		result = daemon_run(project, "-p", "1", env: { "NO_COLOR" => nil }, tty: [40, 120])

		assert(result.success?) { result.screen }
		assert_includes result.stdout, "\e["
		assert_includes result.screen, "PASSED"
		assert_equal boots(project), 2
	end
end
