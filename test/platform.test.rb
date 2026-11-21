# frozen_string_literal: true

require "io/console"

class PlatformTest < Quickdraw::Test
	Platform = Quickdraw::Platform

	# TruffleRuby has no PTY.
	def pty?
		require "pty"
		true
	rescue LoadError
		false
	end

	def terminal(rows:, columns:)
		skip "This Ruby has no PTY" unless pty?

		controller, terminal = PTY.open
		defer { controller.close }
		defer { terminal.close }
		terminal.winsize = [rows, columns]
		terminal
	end

	def cache(levels, kernel: Platform.__send__(:kernel))
		File.join(tmpdir, "core-levels").tap { |path| File.write(path, "#{levels}\n#{kernel}") }
	end

	test "a terminal's columns" do
		assert_equal Platform.terminal_columns(terminal(rows: 24, columns: 132)), 132
	end

	test "a terminal's columns don't take a subprocess where the ioctl is known" do
		skip "No ioctl number for #{RUBY_PLATFORM}" unless Platform::TIOCGWINSZ

		stub(Platform, :stty_columns) { raise "Ran stty." }

		assert_equal Platform.terminal_columns(terminal(rows: 24, columns: 97)), 97
	end

	test "a terminal's columns come from stty when the ioctl fails" do
		io = terminal(rows: 24, columns: 61)
		stub(io, :ioctl) { raise Errno::EINVAL }

		assert_equal Platform.terminal_columns(io), 61
	end

	test "a terminal with no size has no columns" do
		assert_equal Platform.terminal_columns(terminal(rows: 0, columns: 0)), nil
	end

	test "what isn't a terminal has no columns" do
		reader, writer = IO.pipe
		defer { reader.close }
		defer { writer.close }

		assert_equal Platform.terminal_columns(writer), nil
	end

	test "cached core levels that add up to the machine's cores" do
		stub(Platform, :cpu_cores, returns: 12)

		assert_equal Platform.__send__(:cached_core_levels, cache("8 4")), [8, 4]
	end

	test "cached core levels from another machine, or that aren't core levels, are ignored" do
		stub(Platform, :cpu_cores, returns: 12)

		["10 4", "12 0", "12", "8 4 0", "eight four", "-4 16", ""].each do |levels|
			assert_equal Platform.__send__(:cached_core_levels, cache(levels)), nil
		end
	end

	test "cached core levels from a machine with as many cores but another chip are ignored" do
		stub(Platform, :cpu_cores, returns: 10)
		stub(Platform, :kernel, returns: "Darwin Kernel Version 24.0.0; root:xnu-11215~1/RELEASE_ARM64_T8132")

		assert_equal Platform.__send__(:cached_core_levels, cache("8 2", kernel: "Darwin Kernel Version 24.0.0; root:xnu-11215~1/RELEASE_ARM64_T6000")), nil
		assert_equal Platform.__send__(:cached_core_levels, cache("4 6")), [4, 6]
	end

	test "cached core levels that don't say whose they are are ignored" do
		stub(Platform, :cpu_cores, returns: 12)
		path = File.join(tmpdir, "core-levels")
		File.write(path, "8 4")

		assert_equal Platform.__send__(:cached_core_levels, path), nil
	end

	test "no cached core levels without a cache" do
		assert_equal Platform.__send__(:cached_core_levels, File.join(tmpdir, "missing")), nil
	end

	test "core levels are cached in a directory that's made for them" do
		stub(Platform, :cpu_cores, returns: 12)
		path = File.join(tmpdir, "quickdraw", "core-levels")

		Platform.__send__(:cache_core_levels, path, [8, 4])

		assert_equal Platform.__send__(:cached_core_levels, path), [8, 4]
	end

	test "core levels that can't be cached are still used" do
		directory = tmpdir
		File.write(File.join(directory, "file"), "")

		assert_equal Platform.__send__(:cache_core_levels, File.join(directory, "file", "nested", "core-levels"), [8, 4]), nil
	end

	test "the cached core levels are sysctl's" do
		skip "Core levels are only on M-series Macs" unless Platform.m_series?

		assert_equal [Platform.performance_cores, Platform.efficiency_cores], Platform.__send__(:sysctl_core_levels)
	end
end
