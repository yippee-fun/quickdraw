# frozen_string_literal: true

require_relative "../support/integration"

class YJITIntegrationTest < Quickdraw::Test
	include Integration

	STATE = <<~RUBY
		class State < Quickdraw::Test
			test "state" do
				puts "yjit=\#{RubyVM::YJIT.enabled?}"
				assert true
			end
		end
	RUBY

	def state(project, *, **)
		project.run("-p", "1", "--no-capture", *, env: { "RUBY_YJIT_ENABLE" => nil, "RUBY_ZJIT_ENABLE" => nil }, **).stdout[/^yjit=.*$/]
	end

	test "the command line and config choose YJIT", timeout: 30 do
		skip "Workers enable YJIT as they fork" unless Process.respond_to?(:fork)
		skip "This Ruby has no YJIT" unless Quickdraw::Platform.yjit_supported?

		project = project("state.test.rb" => STATE)
		assert_equal state(project, "--no-history"), "yjit=false"
		assert_equal state(project, "--no-history", "--yjit"), "yjit=true"

		configured = project("config/quickdraw.rb" => "Quickdraw.configure do |config|\n\tconfig.yjit = true\nend\n", "state.test.rb" => STATE)
		assert_equal state(configured, "--no-history"), "yjit=true"
		assert_equal state(configured, "--no-history", "--no-yjit"), "yjit=false"
	end

	test "enables YJIT once history expects enough work to repay compiling", timeout: 60 do
		skip "Run history needs sqlite3" unless bundled?("sqlite3")
		skip "Workers enable YJIT as they fork" unless Process.respond_to?(:fork)
		skip "This Ruby has no YJIT" unless Quickdraw::Platform.yjit_supported?

		quick = project("state.test.rb" => STATE)
		assert_equal state(quick), "yjit=false"
		assert_equal state(quick), "yjit=false"

		busy = project("state.test.rb" => STATE, "busy.test.rb" => <<~RUBY)
			class Busy < Quickdraw::Test
				test "busy" do
					clock = -> { Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) }
					started = clock.call
					nil while clock.call - started < #{Quickdraw::Coordinator::YJIT_FROM + 0.3}
					assert true
				end
			end
		RUBY

		assert_equal state(busy, timeout: 30), "yjit=false"
		assert_equal state(busy, timeout: 30), "yjit=true"
		assert_equal state(busy, "--no-yjit", timeout: 30), "yjit=false"

		# A selection that hasn't run, though its files have.
		assert_equal state(busy, "--name", "state"), "yjit=false"
	end

	test "doesn't count time spent waiting as work", timeout: 60 do
		skip "Run history needs sqlite3" unless bundled?("sqlite3")
		skip "Workers enable YJIT as they fork" unless Process.respond_to?(:fork)
		skip "This Ruby has no YJIT" unless Quickdraw::Platform.yjit_supported?

		waiting = project("state.test.rb" => STATE, "waiting.test.rb" => "class Waiting < Quickdraw::Test\n\ttest('waits') { sleep #{Quickdraw::Coordinator::YJIT_FROM + 0.3}; assert true }\nend\n")
		assert_equal state(waiting, timeout: 30), "yjit=false"
		assert_equal state(waiting, timeout: 30), "yjit=false"
	end
end
