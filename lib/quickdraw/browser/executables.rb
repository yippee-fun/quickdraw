# frozen_string_literal: true

require "json"

# Finds what browser tests run: Node, and Playwright's package for it to load.
# `qd browser install` installs the package where `playwright` looks. Nothing
# here downloads.
module Quickdraw::Browser::Executables
	extend self

	# The playwright-core version `qd browser install` installs.
	PLAYWRIGHT_VERSION = "1.64.0"

	# QUICKDRAW_NODE, or `node` on the PATH.
	def node = ENV["QUICKDRAW_NODE"].then { |path| present(path) } || "node"

	# The version of Node `node` runs, or nil if it doesn't.
	def node_version(node = self.node)
		IO.popen([node, "--version"], err: File::NULL, &:read)[/\d+\.\d+\.\d+/]
	rescue SystemCallError
		nil
	end

	# The directory of Playwright's package: QUICKDRAW_PLAYWRIGHT, the project's
	# own playwright-core or playwright, or the one `qd browser install`
	# installed. Nil if there's none.
	def playwright
		[
			present(ENV["QUICKDRAW_PLAYWRIGHT"])&.then { |path| File.expand_path(path) },
			File.expand_path("node_modules/playwright-core"),
			File.expand_path("node_modules/playwright"),
			installed_playwright,
		].compact.find { |path| File.file?(File.join(path, "package.json")) }
	end

	# Where `qd browser install` puts the package.
	def installed_playwright = File.join(directory, "playwright-core", PLAYWRIGHT_VERSION, "package")

	def playwright_version(path) = JSON.parse(File.read(File.join(path, "package.json")))["version"]

	# The oldest Node the package runs on.
	def required_node(path) = JSON.parse(File.read(File.join(path, "package.json"))).dig("engines", "node").to_s[/\d+/].to_i

	# Where `qd browser install` puts Playwright, for every project:
	# QUICKDRAW_BROWSERS_PATH, such as a directory CI caches, or the user's cache.
	def directory = File.expand_path(present(ENV["QUICKDRAW_BROWSERS_PATH"]) || File.join(user_cache, "quickdraw"))

	# The user's cache directory, by each platform's convention.
	def user_cache
		if Quickdraw::Platform.mac_platform?
			File.expand_path("~/Library/Caches")
		elsif Gem.win_platform?
			ENV.fetch("LOCALAPPDATA") { File.expand_path("~/AppData/Local") }
		else
			present(ENV["XDG_CACHE_HOME"]) || File.expand_path("~/.cache")
		end
	end

	# Whether config.browser's `settings` only need Chromium's headless shell,
	# rather than a Chromium that can show its window.
	def headless_shell?(settings)
		launch = settings.fetch(:launch, {})
		settings.fetch(:browsers, ["chromium"]).include?("chromium") && settings.fetch(:headless, true) && launch[:headless] != false && !launch.key?(:channel)
	end

	# The directories Playwright's `install` would put `browser` in that don't
	# exist, so it isn't installed. Empty if it is, and nil if Playwright
	# couldn't say.
	def missing_browsers(path, browser, headless_shell:)
		output = IO.popen([node, File.join(path, "cli.js"), "install", "--dry-run", *("--only-shell" if headless_shell), browser], err: File::NULL, &:read)
		return unless $?.success?

		output.scan(/Install location:\s+(.+)$/).flatten.reject { |location| File.basename(location).start_with?("ffmpeg") || Dir.exist?(location) }
	rescue SystemCallError
		nil
	end

	private def present(value) = (value unless value.nil? || value.empty?)
end
