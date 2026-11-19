# frozen_string_literal: true

require_relative "../support/integration"

class GroupsTest < Quickdraw::Test
	include Integration

	CONFIG = <<~RUBY
		Quickdraw.configure do |config|
			config.group :browser, "test/browser/**/*.test.rb" do
				require_relative "../lib/browser"
			end
		end
	RUBY

	def browser_project(files = {}) = project(
		"config/quickdraw.rb" => CONFIG,
		"lib/browser.rb" => "module Browser; end\n",
		**files,
	)

	test "only a group's tests see what its setup loads", timeout: 20 do
		result = browser_project(
			"test/browser/page.test.rb" => "class Page < Quickdraw::Test; test('has a browser') { assert defined?(Browser) }; end\n",
			"test/model.test.rb" => "class Model < Quickdraw::Test; test('has no browser') { refute defined?(Browser) }; end\n",
		).run("-p", "2", "--no-history")

		assert result.success?
		match { result => { summary: /\A2 tests · 2 assertions/ } }
	end

	test "runs a group's tests with every worker when nothing else is selected", timeout: 20 do
		result = browser_project(
			"test/browser/page.test.rb" => <<~RUBY,
				class Page < Quickdraw::Test
					4.times { |i| test("t\#{i}") { puts "worker \#{ENV['QUICKDRAW_WORKER']}"; sleep 0.2; assert defined?(Browser) } }
				end
			RUBY
		).run("-p", "2", "--no-history", "test/browser")

		assert result.success?
		assert_equal result.stdout.scan(/^worker (\d)$/).flatten.uniq.sort, ["0", "1"]
	end

	test "moves workers to a group that still has work", timeout: 20 do
		result = browser_project(
			"test/browser/slow.test.rb" => <<~RUBY,
				class Slow < Quickdraw::Test
					6.times { |i| test("t\#{i}") { puts "browser worker \#{ENV['QUICKDRAW_WORKER']}"; sleep 0.2; assert true } }
				end
			RUBY
			"test/quick.test.rb" => "class Quick < Quickdraw::Test; test('quick') { assert true }; end\n",
		).run("-p", "2", "--no-history")

		assert result.success?
		# One worker starts in each group; the quick one's moves to the browser group.
		assert_equal result.stdout.scan(/^browser worker (\d)$/).flatten.uniq.sort, ["0", "1"]
	end

	test "bisect replays a group's tests with the group's setup", timeout: 60 do
		project = browser_project(
			"test/browser/polluter.test.rb" => <<~RUBY,
				class Polluter < Quickdraw::Test
					test("pollutes") { Browser.instance_variable_set(:@dirty, true); assert true }
				end
			RUBY
			"test/browser/victim.test.rb" => <<~RUBY,
				class Victim < Quickdraw::Test
					test("expects a clean browser") { refute Browser.instance_variable_get(:@dirty) }
				end
			RUBY
		)

		# See FlakinessTest: the failing seed is found without history, then recorded.
		seed = (1..30).find { |it| !project.run("-p", "1", "--no-history", "--seed", it.to_s).success? }
		refute project.run("-p", "1", "--seed", seed.to_s).success?

		result = project.run("bisect", "test/browser/victim.test.rb:2")

		assert(result.success?) { result.output }
		assert_includes result.stdout, "It fails after:\n  ✗ test/browser/polluter.test.rb:2 Polluter › pollutes\n"
	end

	test "group loaders don't inherit what the coordinator loads for run history", timeout: 20 do
		isolated = "test('isolated') { refute defined?(SQLite3); refute defined?(JSON) }"

		result = browser_project(
			"test/browser/page.test.rb" => "class Page < Quickdraw::Test; #{isolated}; end\n",
			"test/model.test.rb" => "class Model < Quickdraw::Test; #{isolated}; end\n",
		).run("-p", "2")

		assert(result.success?) { result.output }
	end

	test "a worker moving to another group doesn't start until the one before it in its slot has exited", timeout: 20 do
		project = project(
			"config/quickdraw.rb" => <<~RUBY,
				Quickdraw.configure do |config|
					config.group(:browser, "test/browser/*.test.rb") { nil }

					config.after_forking do
						File.open("slots.log", "a") { |file| file.puts "start" }
						at_exit { sleep 0.2; File.open("slots.log", "a") { |file| file.puts "stop" } }
					end
				end
			RUBY
			"test/browser/a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n",
			"test/browser/b.test.rb" => "class B < Quickdraw::Test; test('b') { assert true }; end\n",
			"test/c.test.rb" => "class C < Quickdraw::Test; test('c') { assert true }; end\n",
		)

		assert project.run("-p", "1", "--no-history").success?
		assert_equal File.readlines(File.join(project.directory, "slots.log"), chomp: true), ["start", "stop", "start", "stop"]
	end

	test "a process a group's setup starts doesn't keep the run waiting", timeout: 20 do
		result = project(
			"config/quickdraw.rb" => <<~RUBY,
				Quickdraw.configure do |config|
					config.group(:server, "test/server/*.test.rb") { fork { sleep 30 } }
				end
			RUBY
			"test/server/a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n",
			"test/b.test.rb" => "class B < Quickdraw::Test; test('b') { assert true }; end\n",
		).run("-p", "2", "--no-history")

		assert result.success?
		assert_operator result.duration, :<, 5
	end

	test "a group whose setup fails doesn't stop other tests", timeout: 20 do
		result = project(
			"config/quickdraw.rb" => <<~RUBY,
				Quickdraw.configure do |config|
					config.group(:broken, "test/broken/*.test.rb") { raise "no browser installed" }
				end
			RUBY
			"test/broken/page.test.rb" => "class Page < Quickdraw::Test; test('a') { assert true }; end\n",
			"test/model.test.rb" => "class Model < Quickdraw::Test; test('b') { assert true }; end\n",
		).run("-p", "2", "--no-history")

		refute result.success?
		assert_includes result.output, "✗ test/broken/page.test.rb could not be loaded\n  RuntimeError: The broken group’s setup failed: no browser installed\n    config/quickdraw.rb:2"
		refute_includes result.output, "lib/quickdraw"
		match { result => { summary: /\A1 test · 1 assertion · 1 errored/ } }
	end

	test "explains a group without a pattern", timeout: 20 do
		result = project(
			"config/quickdraw.rb" => "Quickdraw.configure { |config| config.group(:browser) { nil } }\n",
			"a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n",
		).run("-p", "1", "--no-history")

		refute result.success?
		assert_includes result.output, %(The browser group needs a pattern for its files, such as "test/browser/**/*.test.rb".)
	end
end
