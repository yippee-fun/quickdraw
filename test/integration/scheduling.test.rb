# frozen_string_literal: true

require_relative "../support/integration"

class SchedulingTest < Quickdraw::Test
	include Integration

	test "runs tests that history knows are slow first", timeout: 30 do
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
end
