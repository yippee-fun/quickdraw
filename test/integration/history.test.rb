# frozen_string_literal: true

require_relative "../support/integration"

class HistoryTest < Quickdraw::Test
	include Integration

	test "--failed runs failing tests until they pass, even after a narrower run", timeout: 30 do
		project = project(
			"a.test.rb" => <<~RUBY,
				class A < Quickdraw::Test
					test("passes") { assert true }
					test("fails until fixed") { assert ENV["QUICKDRAW_FIXTURE_FIXED"] }
				end
			RUBY
			"b.test.rb" => <<~RUBY,
				class B < Quickdraw::Test
					test("fails until fixed") { assert ENV["QUICKDRAW_FIXTURE_FIXED"] }
				end
			RUBY
		)

		match { project.run("-p", "2") => { summary: /\A3 tests · 3 assertions · 2 failed/ } }
		match { project.run("-p", "2", "--failed") => { summary: /\A2 tests · 2 assertions · 2 failed/ } }

		# Fixing only a.test.rb's failure leaves b.test.rb's for the next --failed.
		match { project.run("-p", "2", "--failed", "a.test.rb", env: { "QUICKDRAW_FIXTURE_FIXED" => "1" }) => { summary: /\A1 test · 1 assertion · / } }
		match { project.run("-p", "2", "--failed") => { summary: /\A1 test · 1 assertion · 1 failed/ } }

		project.run("-p", "2", "--failed", env: { "QUICKDRAW_FIXTURE_FIXED" => "1" })
		assert_includes project.run("-p", "2", "--failed").output, "No tests are failing in the run history."
	end

	test "--failed reruns files that failed to load", timeout: 30 do
		project = project("broken.test.rb" => "raise 'broken'\n")

		project.run("-p", "1")
		result = project.run("-p", "1", "--failed")

		refute result.success?
		assert_includes result.output, "broken.test.rb could not be loaded"
	end

	test "rebuilds a corrupt history and keeps going", timeout: 30 do
		project = project(
			"a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n",
			".quickdraw/history.sqlite3" => "not a database",
		)

		result = project.run("-p", "1")

		assert(result.success?) { result.output }
		refute_includes result.output, "couldn’t"
	end

	test "estimates the worker count, then tunes it from history", timeout: 30 do
		project = project("a.test.rb" => "class A < Quickdraw::Test; 10.times { |i| test(i.to_s) { assert true } }; end\n")

		assert_includes project.run.output, "(estimated)"
		assert_match project.run.output, /workers? \((tuned|exploring)\)/
		assert_includes project.run("-p", "2").output, "2 workers (manual)"
	end
end
