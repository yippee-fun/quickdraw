# frozen_string_literal: true

require_relative "../support/integration"

class ElasticWorkersTest < Quickdraw::Test
	include Integration

	# macOS's, reporting the CPU 98% idle ten times a second, and leaving a
	# file to show it ran.
	IOSTAT = <<~SH
		#!/bin/sh
		touch iostat-ran
		echo '      cpu    load average'
		echo ' us sy id   1m   5m   15m'
		while true; do echo '  1  1 98  0.10 0.10 0.10'; sleep 0.1; done
	SH

	def setup
		super
		skip "Stands in for macOS's iostat" unless RUBY_PLATFORM.include?("darwin")
	end

	def waiting(files:, tests:)
		project(
			"bin/iostat" => IOSTAT,
			**(1..files).to_h do |file|
				["test/wait#{file}.test.rb", <<~RUBY]
					class Wait#{file} < Quickdraw::Test
						#{tests}.times { |i| test("waits \#{i}") { puts "slot=\#{ENV["QUICKDRAW_WORKER"]}"; sleep 0.1; assert true } }
					end
				RUBY
			end,
		).tap { |project| File.chmod(0o755, File.join(project.directory, "bin/iostat")) }
	end

	def run_with_iostat(project, *)
		project.run(*, "--no-capture", env: { "PATH" => "#{File.join(project.directory, 'bin')}:#{ENV.fetch('PATH')}" }, timeout: 30)
	end

	# 32s of tests is enough for workers to be added once a second has gone,
	# whatever the starting count, which follows the machine's cores.
	test "adds workers in new slots while tests wait and CPU is idle", timeout: 40 do
		project = waiting(files: 8, tests: 40)
		result = run_with_iostat(project, "--no-history", "--elastic", "--timeline")

		assert result.success?
		workers, started, added = result.stdout.match(/^    Workers  (\d+) \((\d+) default, (\d+) added as tests waited\)/).captures.map { |count| Integer(count) }
		assert_equal workers, started + added
		slots = result.stdout.scan(/^slot=(\d+)$/).flatten.map { |slot| Integer(slot) }.uniq
		assert slots.max >= started do
			"Slots #{slots.sort.inspect} of #{started} workers"
		end
		assert_match result.stdout, /^  \d+ workers \(\d+ added while running\):/
	end

	test "leaves a worker count that was given alone", timeout: 20 do
		project = waiting(files: 2, tests: 5)
		result = run_with_iostat(project, "--no-history", "--elastic", "-p", "2")

		assert result.success?
		refute File.exist?(File.join(project.directory, "iostat-ran"))
	end

	test "is off unless asked for", timeout: 20 do
		project = waiting(files: 2, tests: 5)
		result = run_with_iostat(project, "--no-history")

		assert result.success?
		refute File.exist?(File.join(project.directory, "iostat-ran"))
	end
end
