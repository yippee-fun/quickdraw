# frozen_string_literal: true

require_relative "../support/integration"

class CoverageTest < Quickdraw::Test
	include Integration

	def setup
		super
		skip "--coverage needs fork" unless Process.respond_to?(:fork)
	end

	CALCULATOR = <<~RUBY
		class Calculator
			def add(a, b) = a + b

			def divide(a, b)
				if b == 0
					raise ArgumentError, "division by zero"
				else
					a / b
				end
			end

			def unused = :never
		end
	RUBY

	def calculator(config: "require_relative \"../lib/calculator\"\n") = project(
		"lib/calculator.rb" => CALCULATOR,
		"lib/orphan.rb" => "class Orphan; end\n",
		"config/quickdraw.rb" => config,
		"test/calculator.test.rb" => <<~RUBY,
			class CalculatorTest < Quickdraw::Test
				test("adds") { assert_equal Calculator.new.add(1, 2), 3 }
				test("divides") { assert_equal Calculator.new.divide(6, 2), 3 }
			end
		RUBY
	)

	test "reports lines, branches and methods, the least covered files and files no test loaded", timeout: 20 do
		result = calculator.run("-p", "2", "--no-history", "--coverage")

		assert result.success?
		assert_includes result.stdout, "Coverage 71% of lines · 50% of branches · 66% of methods"
		assert_match result.stdout, %r{^ +71%  lib/calculator\.rb  missing 6, 12$}
		assert_includes result.stdout, "! Never loaded by a test: lib/orphan.rb"
		refute_includes result.stdout[/^Coverage .*/m], "test/calculator.test.rb"
	end

	test "counts code that ran while config booted once, not once per worker", timeout: 20 do
		project = calculator
		project.run("-p", "3", "--no-history", "--coverage")

		lcov = File.read(File.join(project.directory, ".quickdraw/coverage/lcov.info"))
		assert_includes lcov, "DA:1,1\n"
		assert_includes lcov, "FNDA:1,Calculator#add\n"
		assert_includes lcov, "BRDA:5,0,0,0\nBRDA:5,0,1,1\n"
	end

	test "covers code that tests load themselves, merged across workers", timeout: 20 do
		project = calculator(config: "")
		project.write(
			"test/calculator.test.rb" => "require_relative '../lib/calculator'\n#{File.read(File.join(project.directory, 'test/calculator.test.rb'))}",
			"test/more.test.rb" => "require_relative '../lib/calculator'\nclass More < Quickdraw::Test; test('divides by zero') { assert_raises(ArgumentError) { Calculator.new.divide(1, 0) } }; end\n",
		)

		result = project.run("-p", "2", "--no-history", "--coverage")

		assert result.success?
		assert_includes result.stdout, "Coverage 85% of lines · 100% of branches · 66% of methods"
	end

	test "lists changed lines that no test ran, including in methods nothing calls", timeout: 20 do
		project = calculator
		git = -> (*arguments) { system("git", "-C", project.directory, "-c", "user.name=Quickdraw", "-c", "user.email=quickdraw@example.com", "-c", "commit.gpgsign=false", *arguments, exception: true) }
		git.("init", "--quiet")
		git.("add", "--all")
		git.("commit", "--quiet", "--no-verify", "-m", "Calculator")
		project.write("lib/calculator.rb" => CALCULATOR.sub("def unused = :never", "def unused = :never\n\tdef subtract(a, b) = a - b"))

		result = project.run("-p", "1", "--no-history", "--coverage")

		assert_includes result.stdout, "Changed lines: 0 of 1 covered\n    ✗ lib/calculator.rb:13\n"

		agent = project.run("-p", "1", "--no-history", "--coverage", "--format", "agent")
		assert_includes agent.stdout, "- Uncovered changed lines: lib/calculator.rb:13\n"
	end

	test "finds changed lines in files whose names git quotes or ends with a tab", timeout: 20 do
		project = project(
			"config/quickdraw.rb" => "require_relative '../lib/with space'\nrequire_relative '../lib/quote\"d'\n",
			"lib/with space.rb" => "module Spaced\n\tdef self.run = :ran\nend\n",
			"lib/quote\"d.rb" => "module Quoted\n\tdef self.run = :ran\nend\n",
			"test/a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n",
		)
		git = -> (*arguments) { system("git", "-C", project.directory, "-c", "user.name=Quickdraw", "-c", "user.email=quickdraw@example.com", "-c", "commit.gpgsign=false", *arguments, exception: true) }
		git.("init", "--quiet")
		git.("add", "--all")
		git.("commit", "--quiet", "--no-verify", "-m", "Files")
		project.write("lib/with space.rb" => "module Spaced\n\tdef self.run = :ran\n\tdef self.walk = :walked\nend\n", "lib/quote\"d.rb" => "module Quoted\n\tdef self.run = :ran\n\tdef self.walk = :walked\nend\n")

		result = project.run("-p", "1", "--no-history", "--coverage")

		assert_includes result.stdout, "Changed lines: 0 of 2 covered"
		assert_includes result.stdout, "✗ lib/with space.rb:3"
		assert_includes result.stdout, "✗ lib/quote\"d.rb:3"
	end

	test "keeps a line covered when one of the methods on it ran", timeout: 20 do
		result = project(
			"lib/pair.rb" => "module Pair\n\tdef self.left = :left; def self.right = :right\nend\n",
			"test/pair.test.rb" => "require_relative '../lib/pair'\nclass PairTest < Quickdraw::Test; test('left') { assert_equal Pair.left, :left }; end\n",
		).run("-p", "1", "--no-history", "--coverage")

		assert_includes result.stdout, "Coverage 100% of lines · 50% of methods"
	end

	test "counts untracked files as changed before the first commit, in a project inside a bigger repository", timeout: 20 do
		project = project(
			"app/lib/new.rb" => "module New\n\tdef self.used = :used\n\tdef self.unused = :unused\nend\n",
			"app/test/new.test.rb" => "require_relative '../lib/new'\nclass NewTest < Quickdraw::Test; test('used') { assert_equal New.used, :used }; end\n",
		)
		system("git", "-C", project.directory, "init", "--quiet", exception: true)

		app = Project.new(File.join(project.directory, "app"))
		result = app.run("-p", "1", "--no-history", "--coverage")

		assert_includes result.stdout, "Changed lines: 2 of 3 covered\n    ✗ lib/new.rb:3\n"
	end

	test "reports coverage even when no test loads any source", timeout: 20 do
		project = project(
			"lib/orphan.rb" => "class Orphan; end\n",
			"test/a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n",
		)
		project.run("-p", "1", "--no-history", "--coverage")
		File.write(File.join(project.directory, ".quickdraw/coverage/stale"), "")

		result = project.run("-p", "1", "--no-history", "--coverage")

		assert_includes result.stdout, "! Never loaded by a test: lib/orphan.rb"
		assert File.exist?(File.join(project.directory, ".quickdraw/coverage/coverage.json"))
	end

	test "writes LCOV and JSON, and adds totals to the JSON stream", timeout: 20 do
		require "json"
		project = calculator
		result = project.run("-p", "1", "--no-history", "--coverage", "--format", "json")

		finish = JSON.parse(result.stdout.lines.last)
		assert_equal finish["coverage"]["lines"], { "covered" => 5, "total" => 7 }

		report = JSON.parse(File.read(File.join(project.directory, ".quickdraw/coverage/coverage.json")))
		assert_equal report["files"].keys, ["lib/calculator.rb"]
		assert_equal report["files"]["lib/calculator.rb"]["methods"].map { |method| [method["name"], method["count"]] }.sort,
			[["Calculator#add", 1], ["Calculator#divide", 1], ["Calculator#unused", 0]]
	end

	test "test processes don't load Coverage without --coverage", timeout: 20 do
		result = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { refute defined?(::Coverage) }; end\n").run("-p", "1", "--no-history")

		assert result.success?
	end
end
