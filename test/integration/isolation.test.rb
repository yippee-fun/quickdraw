# frozen_string_literal: true

require_relative "../support/integration"

class IsolationTest < Quickdraw::Test
	include Integration

	test "doesn't load Quickdraw's own dependencies into tests", timeout: 20 do
		skip "Keeping Quickdraw's dependencies out of tests needs fork" unless Process.respond_to?(:fork)

		result = project("leak.test.rb" => <<~RUBY).run("-p", "2", "leak.test.rb")
			class Leak < Quickdraw::Test
				{
					"JSON" => -> { defined?(::JSON) },
					"Integer#to_json" => -> { 1.respond_to?(:to_json) || nil },
					"SQLite3" => -> { defined?(::SQLite3) },
					"OptionParser" => -> { defined?(::OptionParser) },
					"Etc" => -> { defined?(::Etc) },
					"UNIXSocket" => -> { defined?(::UNIXSocket) },
					"Fiddle" => -> { defined?(::Fiddle) },
					"FileUtils" => -> { defined?(::FileUtils) },
				}.each do |name, loaded|
					test(name) { refute(loaded.call) { "\#{name} was loaded" } }
				end
			end
		RUBY

		assert(result.success?) { result.output }
		match { result => { summary: /\A8 tests · 8 assertions/ } }
	end

	test "scopes each file's top-level constants and methods to that file", timeout: 20 do
		files = [1, 2].to_h do |number|
			["#{number}.test.rb", <<~RUBY]
				VALUE = #{number}
				def helper = #{number}

				class Scoped < Quickdraw::Test
					test("sees its own file's definitions") do
						assert_equal VALUE, #{number}
						assert_equal helper, #{number}
					end
				end
			RUBY
		end

		result = project(files).run("-p", "1", "--no-history", "1.test.rb", "2.test.rb")

		assert(result.success?) { result.output }
		match { result => { summary: /\A2 tests · 4 assertions/ } }
	end

	test "runs a test file's tests once, even when another test file requires it", timeout: 20 do
		result = project(
			"a.test.rb" => <<~RUBY,
				require_relative "b.test"

				class A < Quickdraw::Test
					test("a") { assert true }
				end
			RUBY
			"b.test.rb" => <<~RUBY,
				class B < Quickdraw::Test
					test("b1") { assert true }
					test("b2") { assert true }
				end
			RUBY
		).run("-p", "1", "--no-history", "a.test.rb", "b.test.rb")

		match { result => { summary: /\A3 tests · 3 assertions/ } }
	end

	test "runs tests a helper file defines once, for the test file that calls it", timeout: 20 do
		result = project(
			"a.test.rb" => <<~RUBY,
				require_relative "shared"

				class A < Quickdraw::Test
					Shared.define(self)
					test("a") { assert true }
				end
			RUBY
			"b.test.rb" => <<~RUBY,
				require_relative "a.test"

				class B < Quickdraw::Test
					test("b") { assert true }
				end
			RUBY
			"shared.rb" => <<~RUBY,
				module Shared
					def self.define(test_class) = test_class.test("shared") { assert true }
				end
			RUBY
		).run("-p", "1", "--no-history", "a.test.rb", "b.test.rb")

		match { result => { summary: /\A3 tests · 3 assertions/ } }
	end

	test "runs a test once when a required test file calls the helper that defines it", timeout: 20 do
		project = project(
			"a.test.rb" => <<~RUBY,
				module ::Helper
					def self.define(test_class) = test_class.test("helper") { assert true }
				end

				class A < Quickdraw::Test
					test("a") { assert true }
				end

				require_relative "b.test" unless $b
			RUBY
			"b.test.rb" => <<~RUBY,
				$b = true
				require_relative "a.test" unless defined?(Helper)

				class B < Quickdraw::Test
					Helper.define(self)
					test("b") { assert true }
				end
			RUBY
		)

		# Whichever file loads first.
		4.times do |seed|
			result = project.run("-p", "1", "--no-history", "--seed", seed.to_s, "a.test.rb", "b.test.rb")
			match { result => { summary: /\A3 tests · 3 assertions/ } }
		end
	end

	test "gives a test the same random numbers for a seed, whichever worker runs it", timeout: 30 do
		project = project("random.test.rb" => <<~RUBY)
			class Randomness < Quickdraw::Test
				20.times { |i| test("t\#{i}") { puts "\#{i}=\#{rand(1_000_000)}"; assert true } }
			end
		RUBY

		numbers = -> (result) { result.output.scan(/^\d+=\d+$/).sort }
		one_worker = numbers.(project.run("-p", "1", "--no-history", "--no-capture", "--seed", "42", "random.test.rb"))
		four_workers = numbers.(project.run("-p", "4", "--no-history", "--no-capture", "--seed", "42", "random.test.rb"))
		another_seed = numbers.(project.run("-p", "1", "--no-history", "--no-capture", "--seed", "43", "random.test.rb"))

		assert_equal one_worker.size, 20
		assert_equal four_workers, one_worker
		refute_equal another_seed, one_worker
	end
end
