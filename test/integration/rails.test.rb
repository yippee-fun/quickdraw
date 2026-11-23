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
	def problems(result) = Integration.summaries(result.stdout).map { |summary| summary[/\d+ (?:failed|errored)|\z/] }

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
		result = app("test/counts.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--format", "human", "--timings", timeout: 30)
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

		assert_match result.output, /^   Per test  .* · 2\.0 queries \(\d.*\) · 1\.0 factories \(\d/
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
		# ERB that renders differently each time, so the set renders every run.
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

	test "empties only the tables with rows when a worker starts, and none in a database just loaded", timeout: 60 do
		project = app(
			"db/schema.rb" => FIXTURES["db/schema.rb"],
			"app/models/user.rb" => FIXTURES["app/models/user.rb"],
			"app/models/post.rb" => FIXTURES["app/models/post.rb"],
			"app/models/event.rb" => FIXTURES["app/models/event.rb"],
			"config/environment.rb" => <<~RUBY,
				require_relative "application"
				Rails.application.initialize!

				ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
					File.write(File.join(__dir__, "..", "emptied.log"), "\#{payload[:sql]}\\n", mode: "a") if payload[:sql].match?(/\\A(DELETE|TRUNCATE)/)
				end
			RUBY
			"test/empty.test.rb" => "class EmptyTest < Quickdraw::Test\n\ttest('starts empty') { assert_equal [User.count, Post.count, Event.count], [0, 0, 0] }\nend\n",
		)
		database = File.join(project.directory, "db/test.sqlite3_0")
		log = File.join(project.directory, "emptied.log")

		first = project.run("-p", "1", "--no-history", timeout: 30)
		assert first.success? do
			first.output
		end
		refute File.exist?(log)

		sql(
			database,
			"INSERT INTO users (id, name, created_at, updated_at) VALUES (1, 'Stray', '2000-01-01', '2000-01-01')",
			"INSERT INTO posts (title, user_id, created_at, updated_at) VALUES ('Stray', 1, '2000-01-01', '2000-01-01')",
		)

		second = project.run("-p", "1", "--no-history", timeout: 30)
		assert second.success? do
			second.output
		end

		assert_equal File.read(log).scan(/FROM "(\w+)"/).flatten.sort, ["posts", "users"]
	end

	test "lets a class's tests commit with use_transactional_tests = false, then cleans up after each", timeout: 60 do
		project = app(
			FIXTURES.except("test/fixtures/posts.yml", "test/fixtures/events.yml", "test/fixtures.test.rb").merge(
				"test/commit.test.rb" => <<~RUBY,
					class CommitTest < Quickdraw::Test
						self.use_transactional_tests = false

						3.times do |i|
							test("commits \#{i}") do
								assert_equal Post.count, 0
								assert_equal Event.count, 0
								assert_equal User.order(:name).pluck(:name), ["Ada", "Grace"]

								Post.create!(title: "Committed", user: User.find_by!(name: "Ada"))
								Event.create!(name: "Committed")
								User.find_by!(name: "Grace").update!(name: "Changed")
								User.create!(name: "Extra")
							end
						end

						describe "nested" do
							test("commits too") { assert_equal self.class.use_transactional_tests, false }
						end
					end

					class RolledBackTest < Quickdraw::Test
						test("still rolls back") do
							assert_equal self.class.use_transactional_tests, true
							Event.create!(name: "Rolled back")
						end
					end
				RUBY
			),
		)
		database = File.join(project.directory, "db/test.sqlite3_0")

		result = project.run("-p", "1", "--no-history", timeout: 45)
		assert result.success? do
			result.output
		end

		assert_equal sql(database, "SELECT COUNT(*) FROM posts", "SELECT COUNT(*) FROM events"), [[0]]
		assert_equal sql(database, "SELECT name FROM users ORDER BY name"), [["Ada"], ["Grace"]]
	end

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
		# With the tables its foreign keys refer to, so later runs needn't ask.
		assert_equal sql(database, "SELECT tables FROM quickdraw_fixtures WHERE name = 'posts'"), [[%({"posts":[1,["created_at","updated_at"],["users"]]})]]

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

	test "writes a set that renders differently over the rows it had, keeping the sets that refer to it", timeout: 60 do
		project = app(FIXTURES.merge(
			"test/fixtures/users.yml" => "ada:\n  name: <%= Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) %>\n",
			"test/fixtures.test.rb" => <<~RUBY,
				class FixturesTest < Quickdraw::Test
					fixtures :posts, :events

					test("finds the post's user") { assert_equal posts(:hello).user, users(:ada) }
				end
			RUBY
		))
		database = File.join(project.directory, "db/test.sqlite3_0")

		first = project.run("-p", "1", "--no-history", timeout: 30)
		assert first.success? do
			first.output
		end

		users = sql(database, "SELECT id, name FROM users")
		# Loading posts again would set the title back.
		sql(database, "UPDATE posts SET title = 'Kept'")

		second = project.run("-p", "1", "--no-history", timeout: 30)
		assert second.success? do
			second.output
		end

		rendered = sql(database, "SELECT id, name FROM users")
		assert_equal rendered.map(&:first), users.map(&:first)
		refute_equal rendered, users
		assert_equal sql(database, "SELECT title FROM posts"), [["Kept"]]

		# A set that renders differently, with its file gone, is emptied rather than rendered.
		File.delete(File.join(project.directory, "test/fixtures/events.yml"))
		project.write("test/fixtures.test.rb" => File.read(File.join(project.directory, "test/fixtures.test.rb")).sub(", :events", ""))

		third = project.run("-p", "1", "--no-history", timeout: 30)
		assert third.success? do
			third.output
		end

		assert_equal sql(database, "SELECT COUNT(*) FROM events"), [[0]]
	end

	test "replaces rows with no primary key when their set renders differently, keeping the other sets", timeout: 60 do
		project = app(FIXTURES.merge(
			"config/quickdraw.rb" => "Quickdraw.configure { |config| config.rails(fixtures: :all) }\n",
			"db/schema.rb" => FIXTURES["db/schema.rb"].sub(/end\n\z/, <<~RUBY),
					create_table :tags do |t|
						t.string :name
					end

					create_join_table :users, :tags

					create_table :rates, id: false do |t|
						t.string :name
					end

					create_table :notes do |t|
						t.string :name
					end
				end
			RUBY
			"app/models/user.rb" => "class User < ActiveRecord::Base; has_many :posts; has_and_belongs_to_many :tags; end\n",
			"app/models/tag.rb" => "class Tag < ActiveRecord::Base; end\n",
			"test/fixtures/tags.yml" => "ruby:\n  name: Ruby\nrails:\n  name: Rails\n",
			"test/fixtures/users.yml" => "ada:\n  name: <%= Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) %>\n  tags: ruby, rails\n",
			"test/fixtures/rates.yml" => "<% 2.times do |i| %>\nrate_<%= i %>:\n  name: <%= Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) %>\n<% end %>\n",
			# With no model, so the database gives its row an id.
			"test/fixtures/notes.yml" => "note:\n  name: <%= Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) %>\n",
			"test/fixtures.test.rb" => <<~RUBY,
				class FixturesTest < Quickdraw::Test
					test("finds the user's tags") { assert_equal users(:ada).tags.order(:id).to_a, [tags(:ruby), tags(:rails)].sort_by(&:id) }
				end
			RUBY
		))
		database = File.join(project.directory, "db/test.sqlite3_0")

		first = project.run("-p", "1", "--no-history", timeout: 30)
		assert first.success? do
			first.output
		end

		rates = sql(database, "SELECT name FROM rates")
		notes = sql(database, "SELECT name FROM notes")
		# Loading these again would set them back.
		sql(database, "UPDATE posts SET title = 'Kept'", "UPDATE tags SET name = 'Kept' WHERE name = 'Ruby'")

		# Fewer rates, which a table with no primary key needn't keep the count of.
		project.write("test/fixtures/rates.yml" => "rate:\n  name: <%= Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) %>\n")

		second = project.run("-p", "1", "--no-history", timeout: 30)
		assert second.success? do
			second.output
		end

		assert_equal sql(database, "SELECT name FROM tags ORDER BY name"), [["Kept"], ["Rails"]]
		assert_equal sql(database, "SELECT title FROM posts"), [["Kept"]]
		assert_equal sql(database, "SELECT COUNT(*) FROM tags_users"), [[2]]
		assert_equal sql(database, "SELECT COUNT(*) FROM rates"), [[1]]
		refute_includes rates, sql(database, "SELECT name FROM rates").first
		assert_equal sql(database, "SELECT COUNT(*) FROM notes"), [[1]]
		refute_equal sql(database, "SELECT name FROM notes"), notes
	end

	test "renders the fixtures config wants once for every worker, except those that need a database", timeout: 60 do
		project = app(FIXTURES.merge(
			"config/quickdraw.rb" => "Quickdraw.configure { |config| config.rails(fixtures: :all) }\n",
			# With what looks like ERB once rendered, which stays as it is.
			"test/fixtures/users.yml" => %(ada:\n  name: <%= Process.pid %>\ngrace:\n  name: "<%= '<' + '%= 1 %' + '>' %>"\n),
			# Rendered in each worker, with its database rather than the loader's.
			"test/fixtures/events.yml" => "launch:\n  name: <%= Process.pid + Event.count * 0 %>\n",
			"test/fixtures.test.rb" => <<~RUBY,
				class FixturesTest < Quickdraw::Test
					test("reads the sets") do
						assert_equal events(:launch).name, Process.pid.to_s
						refute_equal users(:ada).name, Process.pid.to_s
						assert_equal users(:grace).name, "<" + "%= 1 %" + ">"
						assert_equal posts(:hello).user, users(:ada)
					end
				end
			RUBY
			"test/more.test.rb" => "class MoreTest < Quickdraw::Test\n\ttest('waits for the other worker') { assert sleep(1) }\nend\n",
		))

		# The database the loader would connect to, were it to.
		sql(File.join(project.directory, "db/test.sqlite3"), "CREATE TABLE events (id integer PRIMARY KEY, name varchar)")

		2.times do
			result = project.run("-p", "2", "--no-history", timeout: 30)
			assert result.success? do
				result.output
			end

			names = [0, 1].map { |slot| sql(File.join(project.directory, "db/test.sqlite3_#{slot}"), "SELECT name FROM users ORDER BY id") }
			assert_equal names.first, names.last
			assert_equal names.first.size, 2
		end
	end

	test "loads fixtures again after a test commits, even when another database fails to roll back", timeout: 30 do
		result = app(
			"config/database.yml" => <<~YAML,
				test:
				  primary:
				    adapter: sqlite3
				    database: db/test.sqlite3
				  other:
				    adapter: sqlite3
				    database: db/other.sqlite3
			YAML
			"db/other_schema.rb" => "ActiveRecord::Schema[8.1].define(version: 1) {}\n",
			"app/models/other_record.rb" => "class OtherRecord < ActiveRecord::Base\n\tself.abstract_class = true\n\tconnects_to database: { writing: :other }\nend\n",
			"test/fixtures/users.yml" => "ada:\n  name: Ada\n",
			"test/commit.test.rb" => <<~RUBY,
				class CommitTest < Quickdraw::Test
					fixtures :users

					test("commits") do
						OtherRecord.connection.execute("ROLLBACK")
						User.delete_all
						User.connection.commit_transaction
					end

					5.times do |i|
						test("sees the fixtures \#{i}") { assert_equal User.count, 1 }
					end
				end
			RUBY
		).run("-p", "1", "--seed", "1", "--retry", "0", "--no-history", timeout: 30)

		match { result => { summary: /\A6 tests · 5 assertions · 1 errored ·/ } }
		assert_includes result.stdout, "ActiveRecord::StatementInvalid: SQLite3::SQLException: cannot rollback - no transaction is active"
	end

	test "keeps another database's fixtures when it doesn't empty databases, though no model has connected to it", timeout: 60 do
		project = app(
			"config/quickdraw.rb" => "Quickdraw.configure { |config| config.rails(fixtures: :all) }\n",
			"config/database.yml" => <<~YAML,
				test:
				  primary:
				    adapter: sqlite3
				    database: db/test.sqlite3
				  other:
				    adapter: sqlite3
				    database: db/other.sqlite3
			YAML
			"db/other_schema.rb" => "ActiveRecord::Schema[8.1].define(version: 1) { create_table(:dogs) { |t| t.string :name } }\n",
			"app/models/other_record.rb" => "class OtherRecord < ActiveRecord::Base\n\tself.abstract_class = true\n\tconnects_to database: { writing: :other }\nend\n",
			"app/models/dog.rb" => "class Dog < OtherRecord; end\n",
			"test/fixtures/users.yml" => "ada:\n  name: Ada\n",
			"test/fixtures/dogs.yml" => "rex:\n  name: Rex\n",
			"test/users.test.rb" => "class UsersTest < Quickdraw::Test\n\ttest('users') { assert_equal User.pluck(:name).sort, YAML.load_file('test/fixtures/users.yml').values.map { _1['name'] }.sort }\nend\n",
		)

		first = project.run("-p", "1", "--no-history", timeout: 30)
		assert first.success? do
			first.output
		end

		project.write("test/fixtures/users.yml" => "ada:\n  name: Ada\ngrace:\n  name: Grace\n")
		second = project.run("-p", "1", "--no-history", env: { "SKIP_TEST_DATABASE_TRUNCATE" => "1" }, timeout: 30)

		assert second.success? do
			second.output
		end
	end

	test "needs Rails 7.2 or later", timeout: 30 do
		result = project(
			"config/quickdraw.rb" => "Quickdraw.configure(&:rails)\n",
			"config/environment.rb" => "require 'active_support/notifications'\nmodule Rails; def self.gem_version = Gem::Version.new('7.1.5'); end\n",
			"test/a.test.rb" => "class ATest < Quickdraw::Test; test('a') { assert true }; end\n",
		).run("-p", "1", "--no-history", timeout: 30)

		refute result.success?
		assert_includes result.output, "config.rails needs Rails 7.2 or later, and this is Rails 7.1.5."
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

	# The URL of a PostgreSQL server, without a database, such as
	# postgres://postgres:postgres@localhost.
	POSTGRES = ENV["QUICKDRAW_POSTGRES_URL"]

	# The FIXTURES app on PostgreSQL, with the name of its database, which is
	# dropped afterwards with those named after it.
	def postgres_app(files = {})
		skip "QUICKDRAW_POSTGRES_URL isn’t set" unless POSTGRES
		skip "pg isn’t in the bundle" unless bundled?("pg")

		name = "quickdraw_#{Random.urandom(4).unpack1('H*')}_test"

		defer do
			named = postgres("postgres", "SELECT datname FROM pg_database WHERE datname LIKE '#{name}%'").flatten
			postgres("postgres", *named.map { |database| %(DROP DATABASE "#{database}" WITH (FORCE)) })
		end

		[app(FIXTURES.merge("config/database.yml" => "test:\n  adapter: postgresql\n  url: #{POSTGRES}\n  database: #{name}\n  gssencmode: disable\n", **files)), name]
	end

	def databases(name)
		postgres("postgres", "SELECT datname, oid, datallowconn, shobj_description(oid, 'pg_database') FROM pg_database WHERE datname LIKE '#{name}%' ORDER BY datname")
	end

	test "on PostgreSQL, copies each worker's database from a template with the schema and fixtures, and keeps both while they're unchanged", timeout: 180 do
		project, name = postgres_app

		first = project.run("-p", "1", "--no-history", timeout: 60)
		assert first.success? do
			first.output
		end

		worker, template = built = databases(name)
		assert_equal built.size, 2
		assert_equal worker.first, "#{name}_0"
		assert_match template.first, /\A#{name}_qd_template_\h{16}\z/
		# Clean, as every test rolled back.
		assert_equal worker.last, "Quickdraw #{template.first[-16..]} clean"
		# Nothing can connect to the template.
		assert_equal template[2], "f"
		launch = postgres("#{name}_0", "SELECT name FROM events")
		assert_equal postgres("#{name}_0", "SELECT name FROM users ORDER BY name", "SELECT title FROM posts"), [["Hello"]]

		second = project.run("-p", "1", "--no-history", timeout: 60)
		assert second.success? do
			second.output
		end

		# The same databases, rather than new ones with their names, with what the
		# ERB rendered when the template was built.
		assert_equal databases(name), built
		assert_equal postgres("#{name}_0", "SELECT name FROM events"), launch

		project.write("test/fixtures/users.yml" => "#{FIXTURES['test/fixtures/users.yml']}hopper:\n  name: Grace Hopper\n")

		third = project.run("-p", "1", "--no-history", timeout: 60)
		assert third.success? do
			third.output
		end

		# A new template in place of the old one, and a copy of it.
		changed_worker, changed_template = changed = databases(name)
		assert_equal changed.size, 2
		refute_equal changed_template.first, template.first
		refute_equal changed_worker[1], worker[1]
		assert_equal changed_worker.last, "Quickdraw #{changed_template.first[-16..]} clean"
		assert_equal postgres("#{name}_0", "SELECT name FROM users ORDER BY name"), [["Ada"], ["Grace"], ["Grace Hopper"]]

		project.write("db/schema.rb" => FIXTURES["db/schema.rb"].sub("t.string :title", "t.string :title\n\t\tt.string :subtitle"))

		fourth = project.run("-p", "2", "--no-history", timeout: 60)
		assert fourth.success? do
			fourth.output
		end

		assert_equal databases(name).map(&:first).grep_v(changed_template.first).size, 3
		assert_equal postgres("#{name}_1", "SELECT subtitle FROM posts"), [[nil]]
	end

	test "on PostgreSQL, copies the templates again after a test commits, and over a database a worker died with", timeout: 180 do
		project, name = postgres_app(
			"test/commit.test.rb" => <<~RUBY,
				class CommitTest < Quickdraw::Test
					self.use_transactional_tests = false

					3.times do |i|
						test("commits \#{i}") do
							assert_equal User.order(:name).pluck(:name), ["Ada", "Grace"]
							assert_equal Event.count, 1

							User.find_by!(name: "Grace").update!(name: "Changed")
							Event.create!(name: "Committed")
							Process.kill(:KILL, Process.pid) if ENV["DIE"]
						end
					end
				end
			RUBY
			"test/fixtures.test.rb" => <<~RUBY,
				class TransactionTest < Quickdraw::Test
					test("commits its transaction") do
						assert_equal Event.count, 1
						Event.create!(name: "Committed")
						Event.connection.commit_transaction
					end

					3.times do |i|
						test("rolls back \#{i}") do
							assert_equal Event.count, 1
							assert_equal users(:grace).name, "Grace"
							Event.create!(name: "Rolled back")
						end
					end
				end
			RUBY
		)

		# Each worker dies with its first test, and the last leaves what it committed.
		died = project.run("test/commit.test.rb", "-p", "1", "--retry", "0", "--no-history", env: { "DIE" => "1" }, timeout: 60)
		refute died.success?
		assert_equal postgres("#{name}_0", "SELECT name FROM users ORDER BY name"), [["Ada"], ["Changed"]]
		assert_match databases(name).first.last, /\AQuickdraw \h{16} dirty\z/

		result = project.run("-p", "1", "--no-history", timeout: 60)
		assert result.success? do
			result.output
		end

		assert_equal postgres("#{name}_0", "SELECT name FROM users ORDER BY name", "SELECT COUNT(*) FROM events"), [["1"]]
		assert_equal postgres("#{name}_0", "SELECT name FROM users ORDER BY name"), [["Ada"], ["Grace"]]
		assert_match databases(name).first.last, /\AQuickdraw \h{16} clean\z/
	end

	test "on PostgreSQL, builds no template when config wants no fixtures", timeout: 120 do
		project, name = postgres_app(
			"config/quickdraw.rb" => "Quickdraw.configure { |config| config.rails }\n",
			"test/fixtures.test.rb" => "class EmptyTest < Quickdraw::Test\n\ttest('starts empty') { assert_equal User.count, 0 }\nend\n",
		)

		result = project.run("-p", "1", "--no-history", timeout: 60)
		assert result.success? do
			result.output
		end

		assert_equal databases(name).map(&:first), ["#{name}_0"]
	end

	test "on PostgreSQL, won't start a worker on databases another run's worker holds", timeout: 120 do
		project, name = postgres_app
		reader, writer = IO.pipe

		holder = Process.fork do
			reader.close
			require "pg"
			connection = PG.connect("#{POSTGRES}/postgres?gssencmode=disable")
			connection.exec("SELECT pg_advisory_lock(hashtext('quickdraw worker'), hashtext('#{name}_0'))")
			writer.puts
			sleep
		end

		writer.close
		reader.gets
		defer { Process.kill(:KILL, holder) && Process.wait(holder) }

		result = project.run("-p", "1", "--no-history", "--retry", "0", timeout: 60)
		refute result.success?
		assert_includes result.output, "Another Quickdraw run is using the #{name}_0 database."
		assert_equal databases(name).map(&:first).grep(/_0\z/), []
	end

	# Runs each statement on a SQLite database, returning the last one's rows.
	private def sql(database, *statements)
		in_fork do
			require "sqlite3"
			db = SQLite3::Database.new(database)
			statements.map { |statement| db.execute(statement) }.last
		end
	end

	# As #sql, on a database of the PostgreSQL server. Without GSSAPI, which
	# macOS aborts a fork for using.
	private def postgres(database, *statements)
		in_fork do
			require "pg"
			connection = PG.connect("#{POSTGRES}/#{database}?gssencmode=disable")
			statements.map { |statement| connection.exec(statement).values }.last
		end
	end

	# What the block returns in a fork, so what it requires isn't loaded here.
	private def in_fork
		reader, writer = IO.pipe

		pid = Process.fork do
			reader.close
			writer.write(Marshal.dump(yield))
			exit!(0)
		end

		writer.close
		result = Marshal.load(reader.read)
		Process.wait(pid)
		result
	ensure
		reader&.close
	end
end
