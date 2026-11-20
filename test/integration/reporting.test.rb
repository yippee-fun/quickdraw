# frozen_string_literal: true

require_relative "../support/integration"

class ReportingTest < Quickdraw::Test
	include Integration

	test "exits successfully with a summary, and shows rerun commands only when the run fails", timeout: 20 do
		passed = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n").run("-p", "1", "--seed", "7")

		assert passed.success?
		match { passed => { summary: /\A1 test · 1 assertion · / } }
		assert_match passed.output, /^PASSED  /
		refute_includes passed.output, "--seed"

		failed = project("a.test.rb" => "class A < Quickdraw::Test; test('a') { assert false }; end\n").run("-p", "1", "--seed", "7")

		refute failed.success?

		if bundled?("sqlite3")
			assert_match failed.output, /^  Rerun failures  (bundle exec )?quickdraw --failed\n  Same order      (bundle exec )?quickdraw --seed 7$/
		else
			# Without run history, --failed has nothing to rerun.
			refute_includes failed.output, "--failed"
			assert_match failed.output, /^  Same order  (bundle exec )?quickdraw --seed 7$/
		end
	end

	test "compares the tests' time with the last run of the same tests with --timings", timeout: 30 do
		skip "Run history needs sqlite3" unless bundled?("sqlite3")

		project = project("a.test.rb" => "class A < Quickdraw::Test; 2.times { |i| test(\"t\#{i}\") { sleep Float(ENV['NAP']); assert true } }; end\n")

		project.run("-p", "1", env: { "NAP" => "0.05" })
		slower = project.run("-p", "1", "--format", "human", "--timings", env: { "NAP" => "0.2" })
		faster = project.run("-p", "1", "--format", "human", "--timings", env: { "NAP" => "0.05" })

		assert_match slower.output, /tests \d+% slower than the last run$/
		assert_match faster.output, /tests \d+% faster than the last run$/
		refute_match project.run("-p", "1", "--format", "human", "--timings", "--no-history", env: { "NAP" => "0.2" }).output, /than the last run/
	end

	test "reports failures with the failing line, then exits unsuccessfully", timeout: 20 do
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history")
			class A < Quickdraw::Test
				test("compares strings") do
					assert_equal "hello\\nworld", "hello\\nthere"
				end
			end
		RUBY

		refute result.success?
		assert_includes result.output, "✗ a.test.rb:2 A › compares strings"
		assert_includes result.output, %(  ▸ 3 │   assert_equal "hello\\nworld", "hello\\nthere"\n)
		assert_includes result.output, "- there\n    + world"
	end

	test "shows only the test's frames in an error's backtrace", timeout: 20 do
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history")
			class A < Quickdraw::Test
				test("raises inside an assertion") do
					assert_includes nil, 1
				end
			end
		RUBY

		assert_includes result.output, "NoMethodError"
		assert_includes result.output, "a.test.rb:3"
		refute_includes result.output, "lib/quickdraw"
		refute_includes result.output, "exe/"
	end

	test "lists pending and skipped tests, which don't fail the run", timeout: 20 do
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history")
			class A < Quickdraw::Test
				test "to write later"
				test("skips") { skip "needs a network" }
				test("passes") { assert true }
			end
		RUBY

		assert result.success?
		assert_includes result.output, "  Pending  a.test.rb:2 A › to write later\n"
		assert_includes result.output, "  Skipped  needs a network (1)\n"
		match { result => { summary: /\A3 tests · 1 assertion · 1 skipped · 1 pending/ } }
	end

	test "reports a skip reason that isn't valid UTF-8", timeout: 20 do
		project = project("a.test.rb" => <<~'RUBY')
			class A < Quickdraw::Test
				test("skips") { skip "caf\xE9".b }
			end
		RUBY

		human = project.run("-p", "1", "--no-history")
		assert human.success?
		assert_includes human.output, "  Skipped  caf� (1)\n"

		json = project.run("-p", "1", "--no-history", "--format", "json")
		assert json.success?
		assert_includes json.output, %("skip_reason":"caf�")
	end

	test "groups skips by reason, the most common first, counting those without one", timeout: 20 do
		project = project("a.test.rb" => <<~RUBY)
			class A < Quickdraw::Test
				test("a") { skip "needs a network" }
				test("b") { skip "needs a network" }
				test("c") { skip "" }
				test("d") { skip }
				test("e") { skip "needs a printer\\nand paper" }
			end
		RUBY

		result = project.run("-p", "1", "--no-history")

		assert result.success?
		assert_includes result.output, "  Skipped  needs a network (2) · no reason given (2) · needs a printer (1)\n"
	end

	test "doesn't construct pending tests, and reports a constructor's error as the test's", timeout: 20 do
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history")
			class A < Quickdraw::Test
				def initialize(...)
					raise "no fixtures"
				end

				test "to write later"
				test("runs") { assert true }
			end
		RUBY

		assert_includes result.output, "  Pending  a.test.rb:6 A › to write later\n"
		assert_includes result.output, "✗ a.test.rb:7 A › runs"
		assert_includes result.output, "RuntimeError: no fixtures"
		match { result => { summary: /\A2 tests · 0 assertions · 1 pending · 1 errored/ } }
	end

	test "names tests in describe blocks after each group, and shows the failing line", timeout: 20 do
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history")
			class Shapes < Quickdraw::Test
				describe "squares" do
					describe "#area" do
						test "multiplies" do
							assert_equal 2 * 2, 5
						end
					end
				end
			end
		RUBY

		assert_includes result.output, "✗ a.test.rb:4 Shapes › squares › #area › multiplies"
		assert_includes result.output, "  ▸ 5 │   assert_equal 2 * 2, 5\n"
	end

	test "--failed doesn't rerun skipped or pending tests", timeout: 30 do
		skip "Run history needs sqlite3" unless bundled?("sqlite3")

		project = project("a.test.rb" => <<~RUBY)
			class A < Quickdraw::Test
				test "to write later"
				test("skips") { skip }
				test("fails") { assert false }
			end
		RUBY

		project.run("-p", "1")
		match { project.run("-p", "1", "--failed") => { summary: /\A1 test · 1 assertion · 1 failed/ } }
	end

	test "reports a file that fails to load", timeout: 20 do
		result = project("broken.test.rb" => "raise 'broken'\n").run("-p", "1", "--no-history")

		refute result.success?
		assert_includes result.output, "✗ broken.test.rb could not be loaded"
		assert_includes result.output, "RuntimeError: broken"
	end

	test "notes a slow test that takes most of the run, without --timings", timeout: 20 do
		skip "More than one worker needs fork" unless Process.respond_to?(:fork)

		result = project(
			"a.test.rb" => "class A < Quickdraw::Test; test('slow') { sleep 1.1; assert true }; end\n",
			"b.test.rb" => "class B < Quickdraw::Test; test('fast') { assert true }; end\n",
		).run("-p", "2", "--no-history")

		assert result.success?
		assert_match result.output, /^  Slow  a\.test\.rb:1 A › slow took 1\.\d+s, \d+% of the run\.$/
		refute_includes result.output, "Slowest tests"
	end

	test "lists the slowest tests and files with --timings", timeout: 20 do
		result = project("a.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--timings")
			class A < Quickdraw::Test
				test("slow") { sleep 0.05; assert true }
				test("fast") { assert true }
			end
		RUBY

		assert_includes result.output, "Slowest tests"
		assert_includes result.output, "Slowest files"
		assert_match result.output, /^\s+\d+(\.\d+)?ms\s+a\.test\.rb:2 A › slow/
	end
	test "says what assert_equivalent_html needs when nokogiri isn't installed", timeout: 20 do
		project = project(
			# As require raises it when nokogiri isn't installed.
			"fake/nokogiri.rb" => "error = LoadError.new('cannot load such file -- nokogiri'); error.instance_variable_set(:@path, 'nokogiri'); raise error\n",
			"a.test.rb" => "class A < Quickdraw::Test; test('compares') { assert_equivalent_html '<p>a</p>', '<p>b</p>' }; end\n",
		)

		result = project.run("-p", "1", "--no-history", env: { "RUBYOPT" => "-I#{File.join(project.directory, 'fake')}" })

		refute result.success?
		assert_includes result.output, "assert_equivalent_html needs nokogiri, to compare HTML, which isn’t installed. Add it to the Gemfile’s test group."
	end
end
