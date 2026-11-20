# frozen_string_literal: true

require "tmpdir"

# Browser tests, with Playwright. `config.browser` (see Configuration#browser)
# runs them in a group of their own. Each worker in the group starts a Node
# process that runs Playwright's JavaScript API (see Bridge), which launches a
# browser, and serves the app with Puma, and each test gets a page in a fresh
# browser context, like a private window.
#
#   class SignupTest < Quickdraw::Test
#     include Quickdraw::Browser
#
#     test "signs up" do
#       visit "/signup"
#       page.get_by_label("Email").fill("ada@example.com")
#       page.get_by_role("button", name: "Sign up").click
#       assert_text "Welcome, Ada"
#     end
#   end
#
# This file is loaded wherever config calls `config.browser`, so only what runs
# in the browser group may start Node or load Puma.
module Quickdraw::Browser
	autoload :Server, "quickdraw/browser/server"
	autoload :Recorder, "quickdraw/browser/recorder"
	autoload :Executables, "quickdraw/browser/executables"
	autoload :Bridge, "quickdraw/browser/bridge"
	autoload :Remote, "quickdraw/browser/remote"

	ARTIFACTS = File.join(Quickdraw::ROOT, ".quickdraw", "browser").freeze

	# What Playwright raised, such as when an action timed out.
	class Error < StandardError; end
	class TimeoutError < Error; end

	# Raised in each browser test when the worker's browser couldn't start.
	class Unavailable < StandardError; end

	# Raised when the browser group boots without Puma 7 or later, which isn't
	# one of Quickdraw's dependencies, since only browser tests need it.
	class MissingGem < StandardError; end

	# Each browser test's worker has a browser beside it, which needs a core of
	# its own, and a browser test usually takes far longer than others.
	DEFAULT_CORES = 2
	FILE_SECONDS = 5.0

	# With `browsers`, a group for each, named browser:NAME, with the browser's
	# name as its variant (see Configuration::Group), so each runs every file.
	def self.configure(config, patterns, gemfile:, app:, browsers: nil, cores: DEFAULT_CORES, **settings)
		if config.groups.any? { |group| group.name == "browser" || group.name.start_with?("browser:") }
			raise ArgumentError, "config.browser can only be called once. Give it every pattern, and browsers: for several browsers."
		end

		if browsers
			raise ArgumentError, "config.browser takes browser: or browsers:, not both." if settings.key?(:browser)

			browsers = Array(browsers).map(&:to_s)
			raise ArgumentError, "config.browser’s browsers: needs at least one browser." if browsers.empty?
			if (twice = browsers.find { |name| browsers.count(name) > 1 })
				raise ArgumentError, "config.browser’s browsers: has #{twice} twice."
			end

			browsers.each do |browser|
				raise ArgumentError, "config.browser’s browsers must be chromium, firefox or webkit, not #{browser}." unless browser in "chromium" | "firefox" | "webkit"

				config.group("browser:#{browser}", *patterns, gemfile:, cores:, file_seconds: FILE_SECONDS, browser: true, variant: browser) { prepare(app:, browser:, artifacts: File.join(ARTIFACTS, browser), **settings) }
			end
		else
			config.group(:browser, *patterns, gemfile:, cores:, file_seconds: FILE_SECONDS, browser: true) { prepare(app:, **settings) }
		end

		@settings = { **settings, browsers: browsers || [settings.fetch(:browser, "chromium").to_s], gemfile:, app: !app.nil? }
		config.after_forking { start if @prepared }
	end

	# The options config gave config.browser, with `browsers` the names of
	# those it runs tests in, and whether it gave an app, for commands. Nil if
	# config doesn't call config.browser.
	def self.settings = @settings

	# Why browser tests can't serve the app, and how to fix it, as two sentences.
	MISSING_PUMA = ["config.browser needs puma, to serve the app, which isn’t installed.", "Add it to the Gemfile’s test group."].freeze

	# Server needs rack.response_finished, which Puma calls from 7.0.
	MINIMUM_PUMA = "7"

	# Why the loaded Puma can't serve the app, as two sentences, or nil.
	def self.old_puma
		version = Puma::Const::PUMA_VERSION
		["config.browser needs Puma #{MINIMUM_PUMA} or later, to serve the app, but this is Puma #{version}.", "Update it in the Gemfile."] if Gem::Version.new(version) < Gem::Version.new(MINIMUM_PUMA)
	end

	# In the browser group's loader, once config has booted, so the app has too.
	def self.prepare(app:, browser: "chromium", headless: true, timeout: 5, port: 0, launch: {}, context: {}, artifacts: ARTIFACTS)
		browser = browser.to_s
		raise ArgumentError, "config.browser’s browser must be chromium, firefox or webkit, not #{browser}." unless browser in "chromium" | "firefox" | "webkit"

		if app
			begin
				require "puma"
			rescue LoadError
				raise MissingGem, MISSING_PUMA.join(" ")
			end

			old_puma = self.old_puma
			raise MissingGem, old_puma.join(" ") if old_puma

			# Before the app boots. Puma would default it to development.
			ENV["RACK_ENV"] ||= "test"
			@app = app.call
		end

		@browser_name = browser
		@timeout = timeout
		@port = port
		@options = { browser:, headless:, timeout: timeout * 1000, launch: Remote.argument(launch), context: Remote.argument(context) }
		@prepared = true
		@artifacts = artifacts

		# Only this run's failures.
		Quickdraw.remove_tree(artifacts)
	end

	# Seconds that actions and waiting assertions wait for the page.
	def self.timeout = @timeout

	# The worker's browser: chromium, firefox or webkit.
	def self.browser_name = @browser_name

	# The worker's app server, or nil without an app.
	def self.server = @server

	# In each of the group's workers. Node launches the browser and opens the
	# first page while the worker loads test files. Here rather than in a test,
	# so Node isn't a test's leak. A failure is raised by each test that opens a page.
	def self.start
		@pid = Process.pid
		@server = Server.new(@app, port: @port.zero? ? 0 : @port + Integer(ENV.fetch("QUICKDRAW_WORKER"))) if @app
		@playwright = Executables.playwright
		raise Unavailable, "Playwright isn’t installed. Run `#{Quickdraw::Reporters.command} browser install`, or add playwright-core to the project’s package.json." unless @playwright

		@log = File.join(Dir.tmpdir, "quickdraw-playwright-#{Process.pid}.log")
		@bridge = Bridge.new(node: Executables.node, playwright: @playwright, settings: { **@options, baseURL: @server&.url }, log: @log)
		at_exit { stop if Process.pid == @pid }
	rescue Errno::ENOENT
		@failure = Unavailable.new("Browser tests run Playwright on Node, and Quickdraw couldn’t run `#{Executables.node}`. Install Node, or set QUICKDRAW_NODE to it.")
	rescue => error
		@failure = error
	end

	def self.stop
		@bridge&.stop
		File.delete(@log) if @log && File.exist?(@log)
	end

	# A new page for a test. Node opens the next test's meanwhile, since
	# opening one is most of a browser test's overhead.
	def self.open
		raise "This test file isn’t in the browser group, so it can’t open a page. Add it to config.browser’s patterns." unless @prepared
		raise @failure if @failure
		raise @server.stuck if @server&.stuck

		started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
		ready
		page = Remote.wrap(@bridge, @bridge.call("open"))
		Quickdraw::Counters.add("pages", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
		page
	end

	def self.close(page)
		@bridge.call("close", page: page.__handle__)
	end

	# Waits, in Node, for `kind` (see bridge.mjs's assertions) of `page`. Returns
	# nil if it passes, or why it failed.
	def self.expect(page, kind, within: nil, selector: nil, text: nil, count: nil, timeout: @timeout)
		# Playwright waits forever for a timeout of 0.
		@bridge.call("assert", kind:, page: page.__handle__, within: locator(within), selector: locator(selector), text: Remote.argument(text), count:, timeout: [timeout * 1000, 1].max)
	end

	# Saves a screenshot, the HTML and the console log of the page, named
	# after `name` in the artifacts directory (see .prepare), and returns their paths as lines to show.
	def self.save(page, name)
		base = File.join(@artifacts, "#{name.gsub(/[^\w.-]+/, '-')[0, 100].delete_suffix('-')}-#{Quickdraw.stable_hash(name).to_s(36)[0, 6]}")

		@bridge.call("save", page: page.__handle__, base:, timeout: @timeout * 1000).map do |kind, detail|
			(kind == "Error") ? "Quickdraw couldn’t save the page: #{detail}" : "#{kind}: #{detail.delete_prefix("#{Quickdraw::ROOT}/")}"
		end.join("\n")
	rescue Error => error
		"Quickdraw couldn’t save the page: #{error.message.lines.first&.chomp}"
	end

	# Raises, once Node has tried, why the browser didn't launch.
	private_class_method def self.ready
		@ready ||= @bridge.call("ready")
	rescue Error => error
		install = "Run `#{Quickdraw::Reporters.command} browser install #{@browser_name}` to install it." if error.message.include?("Executable doesn't exist")
		reason = error.message.lines.first.strip
		# Playwright's messages don't always end a sentence, which the hint would run on from.
		reason = "#{reason}." unless reason.end_with?(".", "!", "?")
		@failure = Unavailable.new(["Quickdraw couldn’t launch #{@browser_name} with Playwright #{Executables.playwright_version(@playwright)} (#{@playwright}): #{reason}", install].compact.join(" "))
		raise @failure
	end

	private_class_method def self.locator(target)
		case target
		in nil | String then target
		in Remote then target.__locator__
		end
	end

	def initialize(...)
		super
		@runner = Recorder.new(@runner) { browser_artifacts }
	end

	# The test's page, opened in a fresh browser context when it's first
	# called, and closed after the test. See Remote for its methods.
	def page
		unless @browser_page
			@browser_page = Quickdraw::Browser.open
			defer { close_browser_page }
		end

		@browser_page
	end

	# Goes to `url`, which can be relative to the app's.
	def visit(url)
		page.goto(url)
		nil
	end

	# Waits for the page, or the first element `within` matches, to contain
	# `text`, a String or Regexp. `within` is a selector or a locator.
	def assert_text(text, within: "body", timeout: Quickdraw::Browser.timeout)
		verdict Quickdraw::Browser.expect(page, "text", within:, text:, timeout:)
	end

	# Waits for the page, or the first element `within` matches, not to contain `text`.
	def refute_text(text, within: "body", timeout: Quickdraw::Browser.timeout)
		verdict Quickdraw::Browser.expect(page, "noText", within:, text:, timeout:)
	end

	# Waits for a visible element to match `selector`, a CSS or Playwright
	# selector or a locator, and contain `text` if given; or with `count`, for
	# exactly that many.
	def assert_selector(selector, text: nil, count: nil, timeout: Quickdraw::Browser.timeout)
		verdict Quickdraw::Browser.expect(page, "selector", selector:, text:, count:, timeout:)
	end

	# Waits for no visible element to match `selector` (with `text`, if given).
	def refute_selector(selector, text: nil, timeout: Quickdraw::Browser.timeout)
		verdict Quickdraw::Browser.expect(page, "noSelector", selector:, text:, timeout:)
	end

	# Sleeping makes browser tests slow, or flaky when it's too short, so it's
	# counted and warned about.
	private def sleep(...)
		location = caller_locations(1, 1).first
		warn "#{location.path.delete_prefix("#{Quickdraw::ROOT}/")}:#{location.lineno}: a browser test slept. Wait for what it’s waiting for instead, such as with assert_text."
		started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
		super.tap { Quickdraw::Counters.add("sleeps", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) }
	end

	# A waiting assertion's result: nil if it passed, or why it failed.
	private def verdict(failure)
		if failure
			failure! { failure }
		else
			success!
		end
	end

	# Before the test's transaction rolls back, so the page's requests can't
	# outlast it. Errors the app raised serving them are raised here.
	private def close_browser_page
		server = Quickdraw::Browser.server

		case $!
		in nil | Quickdraw::BasicTest::Skip | Quickdraw::Interrupted
			browser_artifacts if server&.errors?
		else
			browser_artifacts
		end

		begin
			Quickdraw::Browser.close(@browser_page)
		ensure
			@browser_page = nil
			server&.finish(Quickdraw::Browser.timeout)
		end
	end

	# Saved once, when the test first fails or errors, while its page is open.
	private def browser_artifacts
		return @browser_artifacts if @browser_artifacts
		return unless @browser_page

		path, line = @block.source_location
		@browser_artifacts = Quickdraw::Browser.save(@browser_page, "#{path.delete_prefix("#{Quickdraw::ROOT}/").delete_suffix('.test.rb')}-#{line}-#{@description}")
	end
end
