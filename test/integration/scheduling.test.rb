# frozen_string_literal: true

require_relative "../support/integration"

class SchedulingTest < Quickdraw::Test
	include Integration

	test "runs tests that history knows are slow first", timeout: 30 do
		skip "Run history needs sqlite3" unless bundled?("sqlite3")

		project = project("slow.test.rb" => <<~RUBY)
			class Slow < Quickdraw::Test
				10.times { |i| test("fast \#{i}") { puts "ran fast"; assert true } }
				2.times { |i| test("slow \#{i}") { puts "ran slow"; sleep 0.05; assert true } }
			end
		RUBY

		project.run("-p", "1", "--no-capture")

		3.times do |seed|
			ran = project.run("-p", "1", "--no-capture", "--seed", seed.to_s).stdout.scan(/^ran \w+$/)
			assert_equal ran.first(2), ["ran slow", "ran slow"]
		end
	end

	test "starts slow tests on separate workers before loading other files", timeout: 30 do
		skip "Run history needs sqlite3" unless bundled?("sqlite3")
		skip "More than one worker needs fork" unless Process.respond_to?(:fork)

		project = project(
			"slow.test.rb" => "class Slow < Quickdraw::Test; 3.times { |i| test(\"slow \#{i}\") { puts \"started slow\"; sleep 0.3; assert true } }; end\n",
			**(1..12).to_h { |i| ["fast#{i}.test.rb", "puts 'loaded fast'\nclass Fast#{i} < Quickdraw::Test; test('fast') { assert true }; end\n"] },
		)

		project.run("-p", "3", "--no-capture")
		events = project.run("-p", "3", "--no-capture").stdout.scan(/^(?:started slow|loaded fast)$/)

		# Without history, the other workers would load every fast file before
		# taking a slow test. With it, each takes one as soon as it can.
		assert_equal events.count("started slow"), 3
		assert events.rindex("started slow") < events.size - 4 do
			events.inspect
		end
	end

	test "warms up before forking several workers, but not for one", timeout: 30 do
		skip "Workers are forked only with fork" unless Process.respond_to?(:fork)
		skip "Process.warmup needs Ruby 3.3" unless Process.respond_to?(:warmup)

		project = project(
			"config/quickdraw.rb" => "def Process.warmup = File.write('warmups', '.', mode: 'a')\n",
			"a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n",
			"b.test.rb" => "class B < Quickdraw::Test; test('b') { assert true }; end\n",
		)
		warmups = File.join(project.directory, "warmups")

		assert project.run("-p", "1", "--no-history").success?
		refute File.exist?(warmups)

		assert project.run("-p", "2", "--no-history").success?
		assert_equal File.read(warmups), "."
	end
end
