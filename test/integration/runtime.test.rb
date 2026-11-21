# frozen_string_literal: true

require_relative "../support/integration"

class RuntimeIntegrationTest < Quickdraw::Test
	include Integration

	STATE = <<~RUBY
		class State < Quickdraw::Test
			test "state" do
				deferred = GC.enable
				GC.disable if deferred
				puts "yjit=\#{!!defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?} deferred_gc=\#{deferred}"
				assert true
			end
		end
	RUBY

	def state(project, *, **)
		project.run("-p", "1", "--no-capture", *, env: { "RUBY_YJIT_ENABLE" => nil }, **).stdout[/^yjit=.*$/]
	end

	test "the command line and config choose YJIT and deferred GC", timeout: 30 do
		skip "Workers are tuned as they fork" unless Process.respond_to?(:fork)
		skip "This Ruby has no YJIT" unless Quickdraw::Platform.yjit_supported?

		project = project("state.test.rb" => STATE)
		assert_equal state(project, "--no-history"), "yjit=false deferred_gc=false"
		assert_equal state(project, "--no-history", "--yjit", "--defer-gc"), "yjit=true deferred_gc=true"

		configured = project("config/quickdraw.rb" => "Quickdraw.configure do |config|\n\tconfig.yjit = true\n\tconfig.defer_gc = true\nend\n", "state.test.rb" => STATE)
		assert_equal state(configured, "--no-history"), "yjit=true deferred_gc=true"
		assert_equal state(configured, "--no-history", "--no-yjit", "--no-defer-gc"), "yjit=false deferred_gc=false"
	end

	test "defers GC once history expects little work", timeout: 30 do
		skip "Run history needs sqlite3" unless bundled?("sqlite3")
		skip "Workers are tuned as they fork" unless Process.respond_to?(:fork)

		project = project("state.test.rb" => STATE)
		assert_equal state(project), "yjit=false deferred_gc=false"
		assert_equal state(project), "yjit=false deferred_gc=true"
		assert_equal state(project, "--no-defer-gc"), "yjit=false deferred_gc=false"

		# Only some of a file's tests, which history can't size until they've run.
		assert_equal state(project, "--name", "state"), "yjit=false deferred_gc=false"
		assert_equal state(project, "--name", "state"), "yjit=false deferred_gc=true"
	end

	test "enables YJIT once history expects enough work to repay compiling", timeout: 60 do
		skip "Run history needs sqlite3" unless bundled?("sqlite3")
		skip "Workers are tuned as they fork" unless Process.respond_to?(:fork)
		skip "This Ruby has no YJIT" unless Quickdraw::Platform.yjit_supported?

		project = project("state.test.rb" => STATE, "busy.test.rb" => <<~RUBY)
			class Busy < Quickdraw::Test
				test "busy" do
					clock = -> { Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) }
					started = clock.call
					nil while clock.call - started < #{Quickdraw::Runtime::YJIT_FROM + 0.3}
					assert true
				end
			end
		RUBY

		assert_equal state(project, timeout: 30), "yjit=false deferred_gc=false"
		assert_equal state(project, timeout: 30), "yjit=true deferred_gc=false"
	end
end
