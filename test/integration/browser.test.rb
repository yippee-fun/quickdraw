# frozen_string_literal: true

require_relative "../support/integration"

# Needs playwright-ruby-client and puma installed, outside Quickdraw's bundle,
# and a Playwright driver and browser. PLAYWRIGHT_CLI_EXECUTABLE_PATH chooses the
# driver, and QUICKDRAW_TEST_CHROMIUM a Chromium. Skipped where they're missing.
class BrowserTest < Quickdraw::Test
	include Integration

	singleton_class.attr_accessor :unavailable

	APP = {
		"config/quickdraw.rb" => <<~RUBY,
			Quickdraw.configure do |config|
				launch = ENV["QUICKDRAW_TEST_CHROMIUM"] ? { executablePath: ENV["QUICKDRAW_TEST_CHROMIUM"] } : {}

				config.browser("test/browser/**/*.test.rb", launch:, timeout: 2) do
					require_relative "../app"
					App
				end
			end
		RUBY
		"app.rb" => <<~RUBY,
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
	}.freeze

	def app(files) = project(**APP, **files)

	# Skips the test if browser tests can't run here: if Playwright, Puma, the
	# driver or a browser is missing. Other problems fail the test.
	def run_browser(project, *arguments)
		skip BrowserTest.unavailable if BrowserTest.unavailable

		run_quickdraw(project, *arguments).tap do |result|
			BrowserTest.unavailable = case result.output
			in /cannot load such file -- (playwright|puma)/ then "#{$1} isn’t installed"
			in /Quickdraw::Browser::Unavailable: (.*(?:driver didn’t|needs Playwright|Executable doesn't exist).*)/ then $1
			else nil
			end

			skip BrowserTest.unavailable if BrowserTest.unavailable
		end
	end

	# Before a slow project, since finding out from a quick one is quicker.
	def skip_unless_browser
		run_browser(app("test/browser/page.test.rb" => "class PageTest < Quickdraw::Test; include Quickdraw::Browser; test('opens') { page; assert true }; end\n"), "-p", "1")
	end

	# So npx never downloads Playwright.
	def run_quickdraw(project, *) = project.run("--no-history", *, env: { "npm_config_offline" => "true" }, timeout: 30)

	test "other tests don't load Playwright, and can't open a page", timeout: 20 do
		result = run_quickdraw(app("test/model.test.rb" => <<~RUBY), "-p", "1")
			class ModelTest < Quickdraw::Test
				include Quickdraw::Browser

				test("visits") do
					refute defined?(Playwright)
					visit "/"
				end
			end
		RUBY

		refute result.success?
		assert_includes result.output, "This test file isn’t in the browser group, so it can’t open a page. Add it to config.browser’s patterns."
		match { result => { summary: /\A1 test · 1 assertion · 1 errored/ } }
	end

	test "gives each test a fresh page and waits for the page", timeout: 40 do
		result = run_browser(app("test/browser/page.test.rb" => <<~RUBY), "-p", "1")
			class PageTest < Quickdraw::Test
				include Quickdraw::Browser

				test("waits") do
					visit "/"
					page.get_by_role("button", name: "Go").click
					assert_text "Done"
					assert_text(/D.ne/, within: "body")
					assert_text "Hello", within: "h1, button"
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
		match { result => { summary: /\A3 tests · 9 assertions/ } }
	end

	test "a failed or errored test shows its page's screenshot, HTML and console", timeout: 40 do
		project = app("test/browser/page.test.rb" => <<~RUBY)
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

		result = run_browser(project, "-p", "2", "--format", "agent")

		refute result.success?
		assert_includes result.output, "Locator expected to contain text 'Goodbye'"
		assert_includes result.output, "Timeout 100ms exceeded."

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
		result = run_browser(app("test/browser/page.test.rb" => <<~RUBY), "-p", "1", "--format", "agent")
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
		result = run_browser(app("test/browser/page.test.rb" => <<~RUBY), "-p", "1", "--format", "human")
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
		assert_match result.output, /^ +1\.0 pages \(.*\) · 1\.0 sleeps \(.*per test$/
	end

	RAILS_APP = {
		"config/quickdraw.rb" => <<~RUBY,
			Quickdraw.configure do |config|
				config.rails
				launch = ENV["QUICKDRAW_TEST_CHROMIUM"] ? { executablePath: ENV["QUICKDRAW_TEST_CHROMIUM"] } : {}
				config.browser("test/system/**/*.test.rb", launch:, timeout: 2) { Rails.application }
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

	test "the page sees the test's records, which roll back", timeout: 60 do
		skip "Rails isn’t in the bundle" unless $LOAD_PATH.any? { |path| File.exist?(File.join(path, "rails.rb")) }
		skip_unless_browser

		result = run_browser(project(**RAILS_APP, "test/system/users.test.rb" => <<~RUBY), "-p", "2")
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
end
