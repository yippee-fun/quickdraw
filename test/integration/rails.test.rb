# frozen_string_literal: true

require_relative "../support/integration"

class RailsTest < Quickdraw::Test
	include Integration

	APP = {
		"config/quickdraw.rb" => "Quickdraw.configure(&:rails)\n",
		"config/application.rb" => <<~RUBY,
			require "rails"
			require "active_record/railtie"

			class Shop < Rails::Application
				config.load_defaults 8.1
				config.root = File.expand_path("..", __dir__)
				config.eager_load = false
				config.logger = Logger.new(nil)
			end
		RUBY
		"config/environment.rb" => <<~RUBY,
			require_relative "application"
			Rails.application.initialize!
		RUBY
		"config/database.yml" => <<~YAML,
			test:
			  adapter: sqlite3
			  database: db/test.sqlite3
		YAML
		"db/schema.rb" => <<~RUBY,
			ActiveRecord::Schema[8.1].define(version: 1) do
				create_table :users do |t|
					t.string :name
				end
			end
		RUBY
		"app/models/user.rb" => "class User < ActiveRecord::Base; end\n",
	}.freeze

	# Only CRuby's bundle has Rails.
	RAILS = $LOAD_PATH.any? { |path| File.exist?(File.join(path, "rails.rb")) }

	def setup
		super
		skip "Rails isn’t in the bundle" unless RAILS
	end

	def app(files) = project(**APP, **files)

	test "gives each worker a database loaded from the schema, and rolls back each test", timeout: 30 do
		project = app("test/user.test.rb" => <<~RUBY)
			class UserTest < Quickdraw::Test
				10.times do |i|
					test("creates \#{i}") do
						User.create!(name: "Ada")
						assert_equal User.count, 1
						assert_equal ActiveRecord::Base.connection_db_config.database, "db/test.sqlite3_\#{ENV['QUICKDRAW_WORKER']}"
					end
				end
			end
		RUBY

		result = project.run("-p", "2", "--no-history", timeout: 30)

		assert result.success? do
			result.output
		end

		assert File.exist?(File.join(project.directory, "db/test.sqlite3_0"))
		assert File.exist?(File.join(project.directory, "db/test.sqlite3_1"))
	end

	test "threads a test starts share its transaction", timeout: 30 do
		result = app("test/thread.test.rb" => <<~RUBY).run("-p", "1", "--no-history", timeout: 30)
			class ThreadTest < Quickdraw::Test
				test("sees the test's records") do
					User.create!(name: "Ada")
					assert_equal Thread.new { User.count }.value, 1
				end

				test("starts empty") { assert_equal User.count, 0 }
			end
		RUBY

		assert result.success? do
			result.output
		end
	end

	test "reads through a replica see the test's records", timeout: 30 do
		result = app(
			"config/database.yml" => <<~YAML,
				test:
				  primary:
				    adapter: sqlite3
				    database: db/test.sqlite3
				  primary_replica:
				    adapter: sqlite3
				    database: db/test.sqlite3
				    replica: true
			YAML
			"app/models/application_record.rb" => <<~RUBY,
				class ApplicationRecord < ActiveRecord::Base
					self.abstract_class = true
					connects_to database: { writing: :primary, reading: :primary_replica }
				end
			RUBY
			"app/models/user.rb" => "class User < ApplicationRecord; end\n",
			"test/replica.test.rb" => <<~RUBY,
				class ReplicaTest < Quickdraw::Test
					test("reads") do
						User.create!(name: "Ada")
						ApplicationRecord.connected_to(role: :reading) { assert_equal User.count, 1 }
					end

					test("starts empty") { assert_equal User.count, 0 }
				end
			RUBY
		).run("-p", "1", "--no-history", timeout: 30)

		assert result.success? do
			result.output
		end
	end

	# For watch mode: an app with `test` in test/user.test.rb, whose config
	# counts the times it boots, in a log, which watch mode ignores.
	def watched_app(test:, reloading:, eager_load: false) = app(
		"config/quickdraw.rb" => "File.write('boots.log', 'x', mode: 'a')\nQuickdraw.configure(&:rails)\n",
		"config/application.rb" => APP["config/application.rb"].sub("config.eager_load = false", "config.eager_load = #{eager_load}\n\tconfig.enable_reloading = #{reloading}"),
		"app/models/user.rb" => "class User < ActiveRecord::Base\n\tdef greeting = 'hi'\nend\n",
		"test/user.test.rb" => test,
	)

	def boots(project) = File.read(File.join(project.directory, "boots.log")).size

	# Each run's failures or errors.
	def problems(result) = result.stdout.scan(/^(?:PASSED|FAILED) \K\d+ tests? · .*$/).map { |summary| summary[/\d+ (?:failed|errored)|\z/] }

	test "reloads app code it loaded between runs in watch mode, and boots again when an initializer changes", timeout: 60 do
		project = watched_app(
			test: "class UserTest < Quickdraw::Test; test('greets') { assert_equal User.new.greeting, 'hello' }; end\n",
			reloading: true,
			eager_load: true,
		)

		result = project.watch(
			{ "app/models/user.rb" => "class User < ActiveRecord::Base\n\tdef greeting = 'hello'\nend\n" },
			{ "config/initializers/greeting.rb" => "GREETING = 'hello'\n" },
		)

		assert result.success? do
			result.output
		end

		assert_equal problems(result), ["1 failed", "", ""]
		assert_equal boots(project), 2
	end

	test "without reloading, boots again in watch mode only when the autoloader would miss a change", timeout: 60 do
		project = watched_app(reloading: false, test: <<~RUBY)
			class UserTest < Quickdraw::Test
				test("greets") { assert_equal [User.new.greeting, (Post.name if Object.const_defined?(:Post))], ["hello", "Post"] }
			end
		RUBY

		result = project.watch(
			{ "app/models/user.rb" => "class User < ActiveRecord::Base\n\tdef greeting = 'hello'\nend\n" },
			{ "app/models/post.rb" => "class Post < ActiveRecord::Base; end\n" },
		)

		assert result.success? do
			result.output
		end

		assert_equal problems(result), ["1 failed", "1 failed", ""]
		assert_equal boots(project), 2
	end

	test "won't run in a protected environment, since it empties databases", timeout: 30 do
		result = app(
			"config/database.yml" => "#{APP['config/database.yml']}production:\n  adapter: sqlite3\n  database: db/production.sqlite3\n",
			"test/user.test.rb" => "class UserTest < Quickdraw::Test; test('a') { assert true }; end\n",
		).run("-p", "1", "--no-history", env: { "RAILS_ENV" => "production", "SECRET_KEY_BASE" => "secret" }, timeout: 30)

		refute result.success?
		assert_includes result.output, "Tests empty their databases, so they won’t run in the production environment. Set RAILS_ENV=test."
	end

	test "counts each test's queries and factories", timeout: 30 do
		result = app("test/counts.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--format", "human", timeout: 30)
			class CountsTest < Quickdraw::Test
				2.times do |i|
					test("queries \#{i}") do
						ActiveSupport::Notifications.instrument("factory_bot.run_factory") { User.create!(name: "Ada") }
						assert_equal User.where(name: "Ada").count, 1
					end
				end
			end
		RUBY

		assert result.success? do
			result.output
		end

		assert_match result.output, /^ +2\.0 queries \(\d.*\) · 1\.0 factories \(\d/
	end

	FIXTURES = {
		"config/quickdraw.rb" => "Quickdraw.configure { |config| config.rails(fixtures: :users) }\n",
		"db/schema.rb" => <<~RUBY,
			ActiveRecord::Schema[8.1].define(version: 1) do
				create_table :users do |t|
					t.string :name
					t.timestamps
				end

				create_table :posts do |t|
					t.string :title
					t.references :user, foreign_key: { on_delete: :cascade }
					t.timestamps
				end

				create_table :events do |t|
					t.string :name
				end
			end
		RUBY
		"app/models/user.rb" => "class User < ActiveRecord::Base; has_many :posts; end\n",
		"app/models/post.rb" => "class Post < ActiveRecord::Base; belongs_to :user; end\n",
		"app/models/event.rb" => "class Event < ActiveRecord::Base; end\n",
		"test/fixtures/users.yml" => <<~YAML,
			ada:
			  name: Ada
			grace:
			  name: <%= File.read(File.join(__dir__, "grace.txt")) %>
			  updated_at: 2020-01-01 00:00:00
		YAML
		"test/fixtures/grace.txt" => "Grace",
		"test/fixtures/posts.yml" => "hello:\n  title: Hello\n  user: ada\n",
		# ERB that renders differently each time, so the set loads every run.
		"test/fixtures/events.yml" => "launch:\n  name: <%= Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) %>\n",
		"test/fixtures.test.rb" => <<~RUBY,
			class FixturesTest < Quickdraw::Test
				fixtures :posts, :events

				test("finds records by label, once per test") do
					assert_equal users(:ada).name, "Ada"
					assert_equal users(:grace).name, "Grace"
					assert_equal posts(:hello).user, users(:ada)
					assert_equal users(:ada, :grace).map(&:name), ["Ada", "Grace"]
					assert_equal users.size, User.count
					assert_same users(:ada), users(:ada)
					assert_raises(ArgumentError) { users(:nobody) }
				end

				test("fills in timestamps as of loading") do
					assert_operator users(:ada).created_at, :>, 1.hour.ago
					assert_equal users(:grace).updated_at, Time.utc(2020)
				end

				4.times do |i|
					test("rolls back changes \#{i}") do
						assert_equal posts(:hello).title, "Hello"
						assert_equal Post.count, 1
						assert_equal events(:launch).class, Event
						posts(:hello).update!(title: "Changed")
						Post.create!(title: "New", user: users(:grace))
					end
				end
			end
		RUBY
	}.freeze

	test "loads fixtures once into each worker's database, and keeps them for later runs while they're unchanged", timeout: 60 do
		project = app(FIXTURES)
		database = File.join(project.directory, "db/test.sqlite3_0")
		manifest = "SELECT name, digest, loaded_at FROM quickdraw_fixtures ORDER BY name"

		first = project.run("-p", "1", "--no-history", timeout: 30)
		assert first.success? do
			first.output
		end

		loaded = sql(database, manifest)
		assert_equal loaded.map(&:first), ["events", "posts", "users"]

		# As if the users loaded in 2000 and Ada was updated in 1999, with a row
		# committed to posts since.
		sql(
			database,
			"UPDATE users SET created_at = '2000-01-01 00:00:00', updated_at = '1999-01-01 00:00:00' WHERE name = 'Ada'",
			"UPDATE quickdraw_fixtures SET loaded_at = '2000-01-01T00:00:00+00:00' WHERE name = 'users'",
			"INSERT INTO posts (title, created_at, updated_at) VALUES ('Stray', '2000-01-01', '2000-01-01')",
		)

		second = project.run("-p", "1", "--no-history", timeout: 30)
		assert second.success? do
			second.output
		end

		kept = sql(database, manifest)
		# The same digests, except for the ERB that renders differently.
		assert_equal kept.map { |name, digest, _| [name, digest == loaded.assoc(name)[1]] }, [["events", false], ["posts", true], ["users", true]]
		# Kept, with the created_at Rails filled in moved to now, rather than loaded again.
		refute_equal kept.assoc("users")[2], "2000-01-01T00:00:00+00:00"
		assert_equal sql(database, "SELECT updated_at FROM users WHERE name = 'Ada'"), [["1999-01-01 00:00:00"]]
		assert_equal sql(database, "SELECT title FROM posts"), [["Hello"]]

		# Loading users again mustn't cascade to the posts that are kept.
		project.write("test/fixtures/users.yml" => "#{FIXTURES['test/fixtures/users.yml']}hopper:\n  name: Grace Hopper\n")

		third = project.run("-p", "1", "--no-history", timeout: 30)
		assert third.success? do
			third.output
		end

		assert_equal sql(database, "SELECT name FROM users ORDER BY name"), [["Ada"], ["Grace"], ["Grace Hopper"]]
		refute_equal sql(database, manifest).assoc("users")[1], loaded.assoc("users")[1]
	end

	test "Rails' test helpers", timeout: 30 do
		result = app(
			"config/application.rb" => <<~RUBY,
				require "rails"
				require "active_record/railtie"
				require "active_job/railtie"
				require "action_mailer/railtie"

				class Shop < Rails::Application
					config.load_defaults 8.1
					config.root = File.expand_path("..", __dir__)
					config.eager_load = false
					config.logger = Logger.new(nil)
					config.action_mailer.delivery_method = :test
				end
			RUBY
			"app/jobs/greeting_job.rb" => "class GreetingJob < ActiveJob::Base; def perform(name) = User.create!(name:); end\n",
			"app/mailers/greeting_mailer.rb" => <<~RUBY,
				class GreetingMailer < ActionMailer::Base
					def hello = mail(to: "ada@example.com", from: "shop@example.com", subject: "Hello", body: "Hello")
				end
			RUBY
			"test/helpers.test.rb" => <<~RUBY,
				class HelpersTest < Quickdraw::Test
					include Quickdraw::Rails::TimeHelpers
					include Quickdraw::Rails::MailerHelpers

					test("travels in time") do
						travel_to Time.utc(2000)
						assert_equal Time.current.year, 2000
					end

					test("counts records") do
						assert_difference(-> { User.count }) { User.create!(name: "Ada") }
					end

					test("enqueues and performs jobs") do
						assert_enqueued_with(job: GreetingJob, args: ["Ada"]) { GreetingJob.perform_later("Ada") }
						perform_enqueued_jobs
						assert_equal User.pluck(:name), ["Ada"]
					end

					test("delivers emails") do
						assert_emails(1) { GreetingMailer.hello.deliver_now }
						perform_enqueued_jobs { GreetingMailer.hello.deliver_later }
						assert_equal ActionMailer::Base.deliveries.size, 2
					end
				end
			RUBY
		).run("-p", "1", "--no-history", timeout: 30)

		assert result.success? do
			result.output
		end

		match { result => { summary: /\A4 tests · 6 assertions/ } }
	end

	# Runs each statement on a SQLite database, returning the last one's rows. In
	# a fork, so sqlite3 isn't loaded here.
	private def sql(database, *statements)
		reader, writer = IO.pipe

		pid = Process.fork do
			reader.close
			require "sqlite3"
			db = SQLite3::Database.new(database)
			writer.write(Marshal.dump(statements.map { |statement| db.execute(statement) }.last))
			exit!(0)
		end

		writer.close
		rows = Marshal.load(reader.read)
		Process.wait(pid)
		rows
	ensure
		reader&.close
	end
end
