# frozen_string_literal: true

require_relative "../support/integration"

class CommandsTest < Quickdraw::Test
	include Integration

	test "init sets up config, an example test and .gitignore, then leaves them alone", timeout: 20 do
		project = project(".git/HEAD" => "ref: refs/heads/main\n")
		first = project.run("init")

		assert first.success?
		assert_includes first.stdout, "created config/quickdraw.rb"
		assert_includes first.stdout, "created test/example.test.rb"
		assert_equal File.read(File.join(project.directory, ".gitignore")), ".quickdraw/\n"
		match { project.run("-p", "1") => { summary: /\A2 tests · 2 assertions/ } }

		second = project.run("init")
		assert_includes second.stdout, "skipped config/quickdraw.rb (it exists)"
		assert_includes second.stdout, "skipped an example test (there are tests already)"
		assert_includes second.stdout, "skipped .gitignore (it ignores .quickdraw/ already)"
	end

	test "init follows git's own rules for what's ignored", timeout: 20 do
		project = project(".gitignore" => ".quickdraw/\n!.quickdraw/\n", "a.test.rb" => "")
		project.git("init", "--quiet")

		assert_match project.run("doctor").stdout, %r{^  ! Git +git doesn’t ignore \.quickdraw/$}
		project.run("init")
		refute_includes project.run("doctor").stdout, "git doesn’t ignore"
	end

	test "counterpart doesn't take a test for its own source file", timeout: 20 do
		project = project("lib/shop/cart.test.rb" => "", "lib/billing/cart.rb" => "")

		assert_equal project.run("counterpart", "lib/shop/cart.test.rb").stdout, "lib/billing/cart.rb\n"
	end

	test "init adds to an existing .gitignore", timeout: 20 do
		project = project(".gitignore" => "/tmp/", "a.test.rb" => "")
		project.run("init")

		assert_equal File.read(File.join(project.directory, ".gitignore")), "/tmp/\n.quickdraw/\n"
	end

	test "doctor reports what's fine and what isn't", timeout: 20 do
		healthy = project("a.test.rb" => "", "config/quickdraw.rb" => "Quickdraw.configure { |config| config.timeout = 5 }\n").run("doctor")

		assert healthy.success?
		assert_match healthy.stdout, /^  ✓ Ruby +#{Regexp.escape(RUBY_VERSION)}( with YJIT)?$/
		assert_match healthy.stdout, %r{^  ✓ Tests +1 test file \(\*\*/\*\.test\.rb\)$}
		assert_match healthy.stdout, %r{^  ✓ Config +config/quickdraw\.rb boots in }
		# Some platforms warn, such as those without fork.
		assert_match healthy.stdout, /\n\nREADY Tests can run( · \d+ warnings?)?\n/

		broken = project("config/quickdraw.rb" => "raise 'no database'\n").run("doctor")

		assert_equal broken.status.exitstatus, 1
		assert_match broken.stdout, %r{^  ✗ Tests +No test files match \*\*/\*\.test\.rb$}
		assert_match broken.stdout, %r{^  ✗ Config +config/quickdraw\.rb fails to boot\n +RuntimeError: no database$}
		assert_includes broken.stdout, "\n\nNOT READY 2 problems to fix before tests can run\n"
	end

	test "counterpart finds a source file's test and a test's source file", timeout: 20 do
		project = project(
			"lib/shop/cart.rb" => "",
			"test/cart.test.rb" => "",
			"app/models/user.rb" => "",
			"test/models/user.test.rb" => "",
			"lib/tax.rb" => "",
			"test/unit/tax.test.rb" => "",
			"lib/orphan.rb" => "",
		)

		assert_equal project.run("counterpart", "lib/shop/cart.rb").stdout, "test/cart.test.rb\n"
		assert_equal project.run("counterpart", "test/cart.test.rb").stdout, "lib/shop/cart.rb\n"
		assert_equal project.run("counterpart", "app/models/user.rb").stdout, "test/models/user.test.rb\n"
		assert_equal project.run("counterpart", "test/models/user.test.rb").stdout, "app/models/user.rb\n"
		assert_equal project.run("counterpart", "lib/tax.rb").stdout, "test/unit/tax.test.rb\n"

		orphan = project.run("counterpart", "lib/orphan.rb")
		assert_equal orphan.status.exitstatus, 1
		assert_includes orphan.stderr, "No counterpart found for lib/orphan.rb."
	end

	def shell?(name) = system("command -v #{name} > /dev/null")

	def completions(shell)
		path = File.join(tmpdir, "completions")
		File.write(path, project.run("completions", shell).stdout)
		path
	end

	test "bash completes options, formats and commands", timeout: 20 do
		skip "bash isn’t installed" unless shell?("bash")

		script = <<~BASH
			source #{completions('bash')}
			COMP_WORDS=(qt --fa); COMP_CWORD=1; _quickdraw; echo "${COMPREPLY[@]}"
			COMP_WORDS=(qt --format j); COMP_CWORD=2; _quickdraw; echo "${COMPREPLY[@]}"
			COMP_WORDS=(qt doc); COMP_CWORD=1; _quickdraw; echo "${COMPREPLY[@]}"
		BASH

		assert_equal IO.popen(["bash", "-c", script], &:read), "--failed --fail-fast\njson junit\ndoctor\n"
	end

	test "fish completes options, formats and commands", timeout: 20 do
		skip "fish isn’t installed" unless shell?("fish")

		script = "source #{completions('fish')}; complete -C 'qt --format j'; complete -C 'quickdraw hist'"
		output = IO.popen(["fish", "-c", script], &:read)

		assert_equal output.lines.map { |line| line.split("\t").first.chomp }, ["json", "junit", "history"]
	end

	test "zsh completions are valid zsh", timeout: 20 do
		skip "zsh isn’t installed" unless shell?("zsh")

		assert system("zsh", "-n", completions("zsh"))
	end

	test "completions without a shell explains how to install them", timeout: 20 do
		result = project.run("completions")

		assert_equal result.status.exitstatus, 2
		assert_includes result.stderr, %(eval "$(quickdraw completions zsh)")
	end

	test "a file or directory named like a command runs as tests", timeout: 20 do
		project = project("init/a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n")

		match { project.run("-p", "1", "--no-history", "init") => { summary: /\A1 test · / } }
	end

	test "--help lists the commands", timeout: 20 do
		assert_match project.run("--help").stdout, /^Commands\n    init +Create config/
	end
end
