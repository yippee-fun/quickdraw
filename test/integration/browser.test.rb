# frozen_string_literal: true

require_relative "../support/integration"

# Browser tests need Node, and Playwright's package with each browser
# installed for it, which `qt browser install chromium firefox webkit` sets
# up. QUICKDRAW_PLAYWRIGHT can point at another package,
# PLAYWRIGHT_BROWSERS_PATH at its browsers, and QUICKDRAW_NODE at Node. A
# browser that can't run here fails its tests, saying why, rather than
# skipping them, which would hide that they never ran.
class BrowserTest < Quickdraw::Test
	include Integration

	BROWSERS = ["chromium", "firefox", "webkit"].freeze

	# Why a browser can't run here, once a test has found out.
	UNAVAILABLE = {}

	APP = <<~RUBY
		App = lambda do |env|
			case env["PATH_INFO"]
			in "/"
				[200, { "content-type" => "text/html" }, [<<~HTML]]
					<h1>Hello</h1>
					<button onclick="setTimeout(() => document.body.append('Done'), 100)">Go</button>
					<script>console.log("Hi from the page")</script>
				HTML
			in "/boom"
				raise "Boom from the app"
			in "/stream"
				[200, { "content-type" => "text/html" }, Enumerator.new { |body| body << "<h1>Streaming</h1>"; raise "Boom while streaming" }]
			end
		end
	RUBY

	def app(browser, files)
		project(
			"config/quickdraw.rb" => <<~RUBY,
				Quickdraw.configure do |config|
					config.browser("test/browser/**/*.test.rb", browser: "#{browser}", timeout: 2) do
						require_relative "../app"
						App
					end
				end
			RUBY
			"app.rb" => APP,
			**files,
		)
	end

	# Fails at once, after the first test to find out, if `browser` can't run
	# here because Puma, Node, Playwright or the browser is missing.
	def run_browser(browser, project, *arguments)
		unavailable(browser) if UNAVAILABLE[browser]

		run_quickdraw(project, *arguments).tap do |result|
			UNAVAILABLE[browser] = result.output[/Quickdraw::Browser::(?:Unavailable|MissingGem): (.*(?:Playwright isn’t installed|Executable doesn't exist|Failed to launch the browser process|couldn’t run `|needs puma).*)/, 1]
			unavailable(browser) if UNAVAILABLE[browser]
		end
	end

	def unavailable(browser)
		raise "#{browser} can’t run here, so its tests didn’t: #{UNAVAILABLE.fetch(browser)}"
	end

	# Before a slow project, since finding out from a quick one is quicker.
	def require_browser(browser)
		run_browser(browser, app(browser, "test/browser/page.test.rb" => "class PageTest < Quickdraw::Test; include Quickdraw::Browser; test('opens') { page; assert true }; end\n"), "-p", "1")
	end

	def run_quickdraw(project, *, env: {}) = project.run("--no-history", *, env:, timeout: 30)

	test "other tests don't start a browser, and can't open a page", timeout: 20 do
		result = run_quickdraw(app("chromium", "test/model.test.rb" => <<~RUBY), "-p", "1")
			class ModelTest < Quickdraw::Test
				include Quickdraw::Browser

				test("visits") do
					assert_equal Quickdraw::Browser.server, nil
					visit "/"
				end
			end
		RUBY

		refute result.success?
		assert_includes result.output, "This test file isn’t in the browser group, so it can’t open a page. Add it to config.browser’s patterns."
		match { result => { summary: /\A1 test · 1 assertion · 1 errored/ } }
	end

	BROWSERS.each do |browser|
		describe browser do
			test "gives each test a fresh page and waits for the page", timeout: 40 do
				result = run_browser(browser, app(browser, "test/browser/page.test.rb" => <<~RUBY), "-p", "1")
					class PageTest < Quickdraw::Test
						include Quickdraw::Browser

						test("waits") do
							visit "/"
							page.get_by_role("button", name: "Go").click
							assert_text "Done"
							assert_text(/D.ne/, within: "body")
							assert_text "Hello", within: "h1, button"
							assert_text "Hello", within: page.get_by_role("heading")
							assert_selector "h1", text: "Hello"
							assert_selector "button", count: 1
							refute_selector "h2"
							refute_text "Goodbye"
						end

						2.times do |i|
							test("isolated \#{i}") do
								visit "/"
								assert_equal page.evaluate("localStorage.getItem('visited')"), nil
								page.evaluate("localStorage.setItem('visited', 'yes')")
							end
						end
					end
				RUBY

				assert(result.success?) { result.output }
				match { result => { summary: /\A3 tests · 10 assertions/ } }
			end

			test "a failed or errored test shows its page's screenshot, HTML and console", timeout: 40 do
				project = app(browser, "test/browser/page.test.rb" => <<~RUBY)
					class PageTest < Quickdraw::Test
						include Quickdraw::Browser

						test("fails") do
							visit "/"
							assert_text "Goodbye", timeout: 0.1
						end

						test("errors") do
							visit "/"
							page.locator("#missing").click(timeout: 100)
						end
					end
				RUBY

				result = run_browser(browser, project, "-p", "2", "--format", "agent")

				refute result.success?
				assert_includes result.output, "Expected body to contain \"Goodbye\", but its text was \"Hello Go\" after 0.1s."
				assert_includes result.output, "Quickdraw::Browser::TimeoutError: locator.click: Timeout 100ms exceeded."

				["test-browser-page-4-fails", "test-browser-page-9-errors"].each do |name|
					base = result.output[%r{Screenshot: (\.quickdraw/browser/#{name}-\w{1,6})\.png\n}, 1]
					assert(base) { result.output }
					assert_includes result.output, "HTML: #{base}.html\n"
					assert_includes result.output, "Console: #{base}.log\n"
					assert File.size?(File.join(project.directory, "#{base}.png"))
					assert_includes File.read(File.join(project.directory, "#{base}.html")), "<h1>Hello</h1>"
					assert_equal File.read(File.join(project.directory, "#{base}.log")), "log: Hi from the page"
				end
			end

			test "raises what the app raised in the test", timeout: 40 do
				result = run_browser(browser, app(browser, "test/browser/page.test.rb" => <<~RUBY), "-p", "1", "--format", "agent")
					class PageTest < Quickdraw::Test
						include Quickdraw::Browser

						test("visits") do
							visit "/boom"
							assert true
						end

						test("streams") do
							visit "/stream"
							assert true
						end
					end
				RUBY

				refute result.success?
				assert_includes result.output, "RuntimeError: Boom from the app"
				assert_includes result.output, "app.rb:10"
				assert_includes result.output, "RuntimeError: Boom while streaming"
				assert_match result.output, %r{Screenshot: \.quickdraw/browser/test-browser-page-4-visits-\w+\.png}
			end

			test "warns about and counts sleeps", timeout: 40 do
				result = run_browser(browser, app(browser, "test/browser/page.test.rb" => <<~RUBY), "-p", "1", "--format", "human")
					class PageTest < Quickdraw::Test
						include Quickdraw::Browser

						test("sleeps") do
							visit "/"
							sleep 0.01
							assert_text "Goodbye", timeout: 0.1
						end
					end
				RUBY

				refute result.success?
				assert_includes result.output, "test/browser/page.test.rb:6: a browser test slept."
				assert_match result.output, /^   Per test  .* · 1\.0 pages \(.*\) · 1\.0 sleeps \(/
			end
		end
	end

	test "pages have Playwright's API, in Ruby", timeout: 40 do
		result = run_browser("chromium", app("chromium", "app.rb" => <<~RUBY, "test/browser/api.test.rb" => <<~TEST), "-p", "1", "--format", "agent")
			App = lambda do |env|
				case env["PATH_INFO"]
				in "/" then [200, { "content-type" => "text/html" }, [<<~HTML]]
					<title>Signup</title>
					<form action="/welcome">
						<label>Email <input name="email"></label>
						<label><input type="checkbox" name="terms"> I agree</label>
						<select name="plan" aria-label="Plan"><option value="free">Free</option><option value="pro">Pro</option></select>
						<ul><li>Ada</li><li>Grace</li></ul>
						<button>Sign up</button>
					</form>
					<p>Ready
						to go</p>
					<button onclick="document.body.append(confirm('Sure?') ? 'Confirmed' : 'Dismissed')">Ask</button>
				HTML
				in "/welcome" then [200, { "content-type" => "text/html" }, ["<h1>Welcome</h1><p>\#{env['QUERY_STRING']}</p>"]]
				end
			end
		RUBY
			class APITest < Quickdraw::Test
				include Quickdraw::Browser

				test("fills a form") do
					visit "/"
					assert_equal page.title, "Signup"
					page.get_by_label("Email").fill("ada@example.com")
					page.get_by_label("I agree").check
					page.get_by_role("combobox", name: "Plan").select_option("pro")
					assert page.get_by_label("I agree").checked?
					assert_equal page.get_by_label("Email").input_value, "ada@example.com"
					assert_equal page.locator("li").all_text_contents, ["Ada", "Grace"]
					assert_equal page.locator("li").filter(has_text: /grace/i).count, 1
					assert_equal page.locator("ul").filter(has: page.get_by_text("Ada")).count, 1
					assert_equal page.evaluate("(name) => `Hi, ${name}`", "Ada"), "Hi, Ada"
					assert_equal page.screenshot.byteslice(1, 3), "PNG"
					page.get_by_label("Email").focus
					page.keyboard.press("Enter")
					assert_text "email=ada%40example.com&terms=on&plan=pro"
					assert_text "Welcome", within: page.get_by_role("heading", level: 1)
				end

				test("matches text as Playwright does, and dismisses dialogs") do
					visit "/"
					assert_text "Ready to go"
					assert_text(/^Ready$/, within: "p")
					assert_selector "button", text: "sign up"
					refute_selector "button", text: "sign out"
					assert_equal page.evaluate("(data) => data.user_id", { "user_id" => 1 }), 1
					assert_equal page.evaluate("async()=>42"), 42
					page.get_by_role("button", name: "Ask").click
					assert_text "Dismissed"
				end

				test("returns objects as remotes") do
					visit "/"
					item = page.locator("li").first.element_handle
					assert_equal item.text_content, "Ada"
					assert_includes page.locator("li").first.inspect, "locator(\\"li\\").first()"
				end
			end
		TEST

		assert(result.success?) { result.output }
		assert_includes result.output, "3 tests, 3 passed"
	end

	test "the page sees the test's records, which roll back", timeout: 60 do
		skip "Rails isn’t in the bundle" unless $LOAD_PATH.any? { |path| File.exist?(File.join(path, "rails.rb")) }
		require_browser("chromium")

		result = run_browser("chromium", project(**RAILS_APP, "test/system/users.test.rb" => <<~RUBY), "-p", "2")
			class UsersTest < Quickdraw::Test
				include Quickdraw::Browser

				3.times do |i|
					test("lists \#{i}") do
						User.create!(name: "Ada \#{i}")
						visit "/users"
						assert_text "1 users"
						assert_text "Ada \#{i}"
					end

					test("creates \#{i}") do
						visit "/users"
						assert_text "0 users"
						assert_equal page.evaluate("fetch('/users?name=Grace', { method: 'POST' }).then(response => response.status)"), 201
						assert_equal User.count, 1
						visit "/users"
						assert_text "Grace"
					end
				end
			end
		RUBY

		assert(result.success?) { result.output }
		match { result => { summary: /\A6 tests · 18 assertions/ } }
	end

	test "says when Puma isn't installed", timeout: 20 do
		project = app("chromium", "fake/puma.rb" => "raise LoadError, 'cannot load such file -- puma'\n", "test/browser/page.test.rb" => <<~RUBY)
			class PageTest < Quickdraw::Test
				include Quickdraw::Browser
				test("opens") { page }
			end
		RUBY

		result = run_quickdraw(project, "-p", "1", env: { "RUBYOPT" => "-I#{File.join(project.directory, 'fake')}" })

		refute result.success?
		assert_includes result.output, "Quickdraw::Browser::MissingGem: The browser group’s setup failed: config.browser needs puma, to serve the app, which isn’t installed. Add it to the Gemfile’s test group."
	end

	test "doctor says what browser tests are missing", timeout: 20 do
		config = { "a.test.rb" => "", "config/quickdraw.rb" => "Quickdraw.configure { |config| config.browser('test/browser/**/*.test.rb', browser: 'webkit') }\n" }
		without = project(**config).run("doctor", env: { "QUICKDRAW_PLAYWRIGHT" => nil, "QUICKDRAW_BROWSERS_PATH" => tmpdir })

		assert_equal without.status.exitstatus, 1
		assert_match without.stdout, /^  ✗ Browser +Playwright isn’t installed, for browser tests\n +Run `quickdraw browser install`\.$/

		no_node = project(**config).run("doctor", env: { "QUICKDRAW_PLAYWRIGHT" => playwright_fixture, "QUICKDRAW_NODE" => "/missing/node" })

		assert_match no_node.stdout, /^  ✗ Browser +Playwright 9\.9\.9 runs on Node 20 or later, which isn’t installed\n +Install it, or set QUICKDRAW_NODE to it\.$/
	end

	test "browser install never downloads in tests, and says when it's offline", timeout: 20 do
		browsers = tmpdir
		offline = project.run("browser", "install", env: { "QUICKDRAW_PLAYWRIGHT" => nil, "QUICKDRAW_BROWSERS_PATH" => browsers, "http_proxy" => "http://127.0.0.1:9", "https_proxy" => "http://127.0.0.1:9", "no_proxy" => nil, "NO_PROXY" => nil })

		assert_equal offline.status.exitstatus, 1
		assert_match offline.stdout, %r{^✗ Couldn’t download https://registry\.npmjs\.org/playwright-core/[\d.]+ \(.*\)\. Are you offline\?}
		assert_equal Dir.children(browsers), []

		assert_equal project.run("browser", "install", "netscape").status.exitstatus, 2
	end

	# A package.json for a Playwright that needs Node 20, with nothing else.
	def playwright_fixture
		tmpdir.tap { |path| File.write(File.join(path, "package.json"), '{ "version": "9.9.9", "engines": { "node": ">=20" } }') }
	end

	RAILS_APP = {
		"config/quickdraw.rb" => <<~RUBY,
			Quickdraw.configure do |config|
				config.rails
				config.browser("test/system/**/*.test.rb", timeout: 2) { Rails.application }
			end
		RUBY
		"config/application.rb" => <<~RUBY,
			require "rails"
			require "active_record/railtie"
			require "action_controller/railtie"

			class Shop < Rails::Application
				config.load_defaults 8.1
				config.root = File.expand_path("..", __dir__)
				config.eager_load = false
				config.logger = Logger.new(nil)
				config.secret_key_base = "secret"
			end
		RUBY
		"config/environment.rb" => "require_relative \"application\"\nRails.application.initialize!\n",
		"config/routes.rb" => "Rails.application.routes.draw { resources :users, only: [:index, :create] }\n",
		"config/database.yml" => "test:\n  adapter: sqlite3\n  database: db/test.sqlite3\n",
		"db/schema.rb" => "ActiveRecord::Schema[8.1].define(version: 1) { create_table(:users) { |t| t.string :name } }\n",
		"app/models/user.rb" => "class User < ActiveRecord::Base; end\n",
		"app/controllers/users_controller.rb" => <<~RUBY,
			class UsersController < ActionController::Base
				skip_forgery_protection

				def index
					render html: "<h1>\#{User.count} users</h1><ul>\#{User.pluck(:name).map { "<li>\#{_1}</li>" }.join}</ul>".html_safe
				end

				def create
					User.create!(name: params[:name])
					head :created
				end
			end
		RUBY
	}.freeze
end
