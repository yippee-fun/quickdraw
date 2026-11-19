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

		assert_match result.output, /^  Counts  2\.0 queries \(\d.*\) · 1\.0 factories \(\d/
	end
end
