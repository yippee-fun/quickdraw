# frozen_string_literal: true

# Browser tests, with Playwright. `config.browser` (see Configuration#browser)
# runs them in a group of their own, so other tests never load Playwright. Each
# worker in the group launches a browser and serves the app with Puma, and each
# test gets a page in a fresh browser context, like a private window.
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
# in the browser group may use Playwright or Puma.
module Quickdraw::Browser
	autoload :Server, "quickdraw/browser/server"
	autoload :Recorder, "quickdraw/browser/recorder"

	ARTIFACTS = File.join(Quickdraw::ROOT, ".quickdraw", "browser")

	# Seconds, long enough for npx to download it.
	DRIVER_TIMEOUT = 60

	# A test's browser context and page, and what the page logged.
	Tab = Data.define(:context, :page, :console)

	# Raised in each browser test when the worker's browser couldn't start.
	class Unavailable < StandardError; end

	def self.configure(config, patterns, gemfile:, app:, **settings)
		config.group(:browser, *patterns, gemfile:) { prepare(app:, **settings) }
		config.after_forking { start if @prepared }
	end

	# In the browser group's loader, once config has booted, so the app has too.
	def self.prepare(app:, browser: "chromium", headless: true, timeout: 5, port: 0, driver: nil, launch: {}, context: {})
		browser = browser.to_s
		raise ArgumentError, "config.browser’s browser must be chromium, firefox or webkit, not #{browser}." unless browser in "chromium" | "firefox" | "webkit"

		require "playwright"
		require "shellwords"

		if app
			require "puma"
			# Before the app boots. Puma would default it to development.
			ENV["RACK_ENV"] ||= "test"
			@app = app.call
		end

		@browser_name = browser
		@headless = headless
		@timeout = timeout
		@port = port
		@driver = driver || ENV["PLAYWRIGHT_CLI_EXECUTABLE_PATH"].then { |path| path unless path.nil? || path.empty? } || default_driver
		@launch_options = launch
		@context_options = context
		@prepared = true

		# Only this run's failures.
		Quickdraw.remove_tree(ARTIFACTS)
	end

	# Seconds that actions and waiting assertions wait for the page.
	def self.timeout = @timeout

	# The worker's app server, or nil without an app.
	def self.server = @server

	# In each of the group's workers. The browser launches in the background, so
	# the worker loads test files meanwhile. A failure is raised by each test
	# that opens a page.
	def self.start
		# playwright-ruby-client decodes the driver's messages in the default
		# external encoding, and hangs on non-ASCII ones in the C locale.
		Encoding.default_external = Encoding::UTF_8

		@pid = Process.pid
		@server = Server.new(@app, port: @port.zero? ? 0 : @port + Integer(ENV.fetch("QUICKDRAW_WORKER"))) if @app

		# Here rather than in a test, so the driver process isn't a test's leak.
		# Bounded, since the worker isn't ready, or watched, until it's done.
		creating = in_background { Playwright.create(playwright_cli_executable_path: @driver) }

		@execution = begin
			# Raises what the thread raised.
			raise Unavailable, "Playwright’s driver, `#{@driver}`, didn’t start within #{DRIVER_TIMEOUT}s." unless creating.join(DRIVER_TIMEOUT)

			creating.value
		rescue Playwright::Error, SystemCallError => error
			raise unavailable(error)
		end

		@spare = in_background { open_tab }
		at_exit { stop if Process.pid == @pid }
	rescue => error
		@failure = error
	end

	# The driver closes the browser when its input closes. Puma's threads end with
	# the worker, so a request that never finishes can't hold it up.
	def self.stop
		@execution&.stop
	end

	# A new tab for a test. The next test's opens meanwhile, since opening a
	# page is most of a browser test's overhead.
	def self.open
		raise "This test file isn’t in the browser group, so it can’t open a page. Add it to config.browser’s patterns." unless @prepared
		raise @failure if @failure
		raise @server.stuck if @server&.stuck

		started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
		tab = @spare.value
		@spare = in_background { open_tab }
		Quickdraw::Counters.add("pages", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
		tab
	end

	# Saves a screenshot, the HTML and the console log of the tab's page, named
	# after `name` in ARTIFACTS, and returns their paths as lines to show.
	def self.save(tab, name)
		base = File.join(ARTIFACTS, "#{name.gsub(/[^\w.-]+/, '-')[0, 100].delete_suffix('-')}-#{Quickdraw.stable_hash(name).to_s(36)[0, 6]}")
		saved = []

		begin
			make_directory(ARTIFACTS)
			tab.page.screenshot(path: "#{base}.png", fullPage: true, timeout: @timeout * 1000)
			saved << "Screenshot: #{relative("#{base}.png")}"
			File.write("#{base}.html", tab.page.content)
			saved << "HTML: #{relative("#{base}.html")}"

			unless tab.console.empty?
				File.write("#{base}.log", tab.console.join("\n"))
				saved << "Console: #{relative("#{base}.log")}"
			end
		rescue Playwright::Error, SystemCallError => error
			saved << "Quickdraw couldn’t save the page: #{error.message.lines.first&.chomp}"
		end

		saved.join("\n")
	end

	private_class_method def self.open_tab
		@browser ||= launch
		context = @browser.new_context(baseURL: @server&.url, **@context_options)
		context.set_default_timeout(@timeout * 1000)
		page = context.new_page
		console = []
		page.on("console", -> (message) { console << "#{message.type}: #{message.text}" })
		page.on("pageerror", -> (error) { console << "uncaught: #{error.message}" })
		Tab.new(context:, page:, console:)
	end

	private_class_method def self.launch
		@execution.playwright.public_send(@browser_name).launch(headless: @headless, **@launch_options)
	rescue Playwright::Error => error
		raise unavailable(error)
	end

	private_class_method def self.unavailable(error)
		message = "Quickdraw couldn’t start #{@browser_name} with Playwright’s driver, `#{@driver}`: #{error.message.strip}"
		compatible = Playwright::COMPATIBLE_PLAYWRIGHT_VERSION
		install = "Install it with `npm install playwright@#{compatible}`, or set PLAYWRIGHT_CLI_EXECUTABLE_PATH to another driver."

		case driver_version
		in nil
			message += ". The driver didn’t run. #{install}"
		in String => version if version.split(".").first(2) != compatible.split(".").first(2)
			message += ". playwright-ruby-client #{Playwright::VERSION} needs Playwright #{compatible}, but the driver is #{version}. #{install}"
		else
			nil
		end

		Unavailable.new(message)
	end

	private_class_method def self.driver_version
		IO.popen("#{@driver} --version", err: File::NULL, &:read)[/\d+\.\d+\.\d+\S*/]
	rescue SystemCallError
		nil
	end

	# The project's own Playwright, if it has one, which starts faster than npx.
	# Otherwise the version playwright-ruby-client needs, since others may not work.
	private_class_method def self.default_driver
		local = File.expand_path("node_modules/.bin/playwright")
		# A command, which playwright-ruby-client runs with a shell.
		File.executable?(local) ? Shellwords.escape(local) : "npx playwright@#{Playwright::COMPATIBLE_PLAYWRIGHT_VERSION}"
	end

	private_class_method def self.in_background(&block)
		Thread.new do
			Thread.current.name = "quickdraw-browser"
			# Raised again by Thread#value.
			Thread.current.report_on_exception = false
			block.call
		end
	end

	private_class_method def self.make_directory(path)
		return if Dir.exist?(path)

		make_directory(File.dirname(path))
		Dir.mkdir(path)
	rescue Errno::EEXIST
		nil
	end

	private_class_method def self.relative(path) = path.delete_prefix("#{Quickdraw::ROOT}/")

	def initialize(...)
		super
		@runner = Recorder.new(@runner) { browser_artifacts }
	end

	# The test's page, opened in a fresh browser context when it's first called,
	# and closed after the test.
	def page
		unless @browser_tab
			@browser_tab = Quickdraw::Browser.open
			defer { close_browser_tab }
		end

		@browser_tab.page
	end

	# Goes to `url`, which can be relative to the app's.
	def visit(url) = page.goto(url)

	# Waits for the page, or the first element `within` matches, to contain
	# `text`, a String or Regexp. `within` is a selector or Playwright locator.
	def assert_text(text, within: "body", timeout: Quickdraw::Browser.timeout)
		wait_for_assertion(locate(within).first, timeout) { |it| it.to_contain_text(text) }
	end

	# Waits for the page, or the first element `within` matches, not to contain `text`.
	def refute_text(text, within: "body", timeout: Quickdraw::Browser.timeout)
		wait_for_assertion(locate(within).first, timeout) { |it| it.not_to_contain_text(text) }
	end

	# Waits for a visible element to match `selector`, a CSS or Playwright
	# selector or a locator, and contain `text` if given; or with `count`, for
	# exactly that many.
	def assert_selector(selector, text: nil, count: nil, timeout: Quickdraw::Browser.timeout)
		locator = locate(selector).filter(hasText: text, visible: true)

		if count
			wait_for_assertion(locator, timeout) { |it| it.to_have_count(count) }
		else
			wait_for_assertion(locator.first, timeout, &:to_be_visible)
		end
	end

	# Waits for no visible element to match `selector` (with `text`, if given).
	def refute_selector(selector, text: nil, timeout: Quickdraw::Browser.timeout)
		wait_for_assertion(locate(selector).filter(hasText: text, visible: true), timeout) { |it| it.to_have_count(0) }
	end

	# Sleeping makes browser tests slow, or flaky when it's too short, so it's
	# counted and warned about.
	private def sleep(...)
		location = caller_locations(1, 1).first
		warn "#{location.path.delete_prefix("#{Quickdraw::ROOT}/")}:#{location.lineno}: a browser test slept. Wait for what it’s waiting for instead, such as with assert_text."
		started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
		super.tap { Quickdraw::Counters.add("sleeps", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) }
	end

	# Retried in the browser, by Playwright, until it passes or times out.
	private def wait_for_assertion(locator, timeout)
		yield locator._assertions(timeout * 1000, false, nil)
		success!
	rescue Playwright::AssertionError => error
		failure! { error.message.strip }
	end

	private def locate(target)
		case target
		in String then page.locator(target)
		in Playwright::Locator then target
		end
	end

	# Before the test's transaction rolls back, so the page's requests can't
	# outlast it. Errors the app raised serving them are raised here.
	private def close_browser_tab
		server = Quickdraw::Browser.server

		case $!
		in nil | Quickdraw::BasicTest::Skip | Quickdraw::Interrupted
			browser_artifacts if server&.errors?
		else
			browser_artifacts
		end

		begin
			@browser_tab.context.close
		ensure
			@browser_tab = nil
			server&.finish(Quickdraw::Browser.timeout)
		end
	end

	# Saved once, when the test first fails or errors, while its page is open.
	private def browser_artifacts
		return @browser_artifacts if @browser_artifacts
		return unless @browser_tab

		path, line = @block.source_location
		@browser_artifacts = Quickdraw::Browser.save(@browser_tab, "#{path.delete_prefix("#{Quickdraw::ROOT}/").delete_suffix('.test.rb')}-#{line}-#{@description}")
	end
end
