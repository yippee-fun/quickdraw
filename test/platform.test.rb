# frozen_string_literal: true

require "pty"
require "io/console"

class PlatformTest < Quickdraw::Test
	Platform = Quickdraw::Platform

	def terminal(rows:, columns:)
		controller, terminal = PTY.open
		defer { controller.close }
		defer { terminal.close }
		terminal.winsize = [rows, columns]
		terminal
	end

	def cache(contents)
		File.join(tmpdir, "core-levels").tap { |path| File.write(path, contents) }
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

		["10 4", "12 0", "12", "8 4 0", "eight four", "-4 16", ""].each do |contents|
			assert_equal Platform.__send__(:cached_core_levels, cache(contents)), nil
		end
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
