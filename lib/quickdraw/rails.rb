# frozen_string_literal: true

# Set up by `config.rails` (see Configuration#rails). The app boots once, before
# workers fork. Each worker slot gets its own databases, named like Rails'
# parallel test databases (test.sqlite3_0, myapp_test_1), created or emptied
# and loaded from the schema when the worker starts, with fixtures (see
# Fixtures). Each test runs in a transaction on every database, rolled back
# afterwards, and counts its SQL queries and factory_bot factories.
module Quickdraw::Rails
	extend self

	autoload :Fixtures, "quickdraw/rails/fixtures"
	autoload :MinitestBridge, "quickdraw/rails/minitest_bridge"
	autoload :TimeHelpers, "quickdraw/rails/time_helpers"
	autoload :JobHelpers, "quickdraw/rails/job_helpers"
	autoload :MailerHelpers, "quickdraw/rails/mailer_helpers"

	def setup(config, environment:, fixtures:, fixture_paths:)
		config.before_forking { boot(environment, fixtures:, fixture_paths:) }
		config.after_forking { start_worker }
		config.around_test { |_test, run| in_transactions(&run) }
		config.reloader { |paths| reload(paths) }
	end

	# Reloads app code in watch mode's loader, when the test environment enables
	# reloading and the main autoloader manages every path. It can't tell
	# whether it ignores a deleted file, which reloading drops anyway.
	def reload(paths)
		autoloader = ::Rails.autoloaders.main
		return false unless ::Rails.application.config.reloading_enabled?

		managed = paths.all? do |path|
			File.exist?(path) ? autoloader.cpath_expected_at(path) : autoloader.dirs.any? { |dir| path.start_with?("#{dir}/") }
		end

		return false unless managed

		::Rails.application.reloader.reload!
		ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord::Base)
		true
	end

	def boot(environment, fixtures:, fixture_paths:)
		ENV["RAILS_ENV"] ||= "test"
		require File.expand_path(environment)

		unless defined?(ActiveRecord::Base)
			raise "Fixtures need Active Record." if fixtures

			return
		end

		if ActiveRecord::Base.protected_environments.include?(::Rails.env)
			raise "Tests empty their databases, so they won’t run in the #{::Rails.env} environment. Set RAILS_ENV=test."
		end

		Fixtures.paths = fixture_paths.map { |path| File.expand_path(path, ::Rails.root) }
		Quickdraw::BasicTest.extend(Fixtures::Declarations)
		Quickdraw::BasicTest.fixtures(*fixtures) if fixtures

		# Forked workers mustn't share the loader's connections.
		ActiveRecord::Base.connection_handler.clear_all_connections!
	end

	def start_worker
		count_events
		return unless defined?(ActiveRecord::Base)

		create_databases(ENV.fetch("QUICKDRAW_WORKER"))
		@pools = []
		@shared_pool_configs = []
		transact_on_new_connections
		Fixtures.start
	end

	# Pins a connection on each writing pool in a transaction, so the test's
	# threads, such as a browser test's server, share it and see its data.
	# Reading roles use the writing pools meanwhile, as in Rails' own tests.
	def in_transactions
		return yield unless @pools

		begin
			@transacting = true
			share_writing_pools
			ActiveRecord::Base.connection_handler.connection_pool_list(ActiveRecord.writing_role).each { |pool| transact(pool) }

			yield
		ensure
			@transacting = false
			finish_transactions
		end
	end

	# Rolls back every pool even if one fails, so the next test starts clean.
	# Fixtures load again if the test committed, which may have changed them.
	private def finish_transactions
		failure = nil
		committed = false

		@pools.each do |pool|
			committed = true unless pool.unpin_connection!
		rescue => error
			failure ||= error
		end

		@pools.clear
		@shared_pool_configs.each { |manager, role, shard, pool_config| manager.set_pool_config(role, shard, pool_config) }
		@shared_pool_configs.clear

		Fixtures.reload if committed
		raise failure if failure
	end

	private def transact(pool)
		return if @pools.include?(pool)

		pool.pin_connection!(true)
		pool.lease_connection
		@pools << pool
	end

	# A model on a database no test has used yet connects mid-test.
	private def transact_on_new_connections
		ActiveSupport::Notifications.subscribe("!connection.active_record") do |*, payload|
			next unless @transacting && payload[:connection_name]

			pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(payload[:connection_name], role: ActiveRecord.writing_role, shard: payload[:shard])
			next unless pool

			share_writing_pools
			transact(pool)
		end
	end

	private def share_writing_pools
		handler = ActiveRecord::Base.connection_handler

		handler.connection_pool_names.each do |name|
			manager = handler.__send__(:connection_name_to_pool_manager)[name]

			manager.shard_names.each do |shard|
				writing = manager.get_pool_config(ActiveRecord.writing_role, shard) or next

				manager.role_names.each do |role|
					pool_config = manager.get_pool_config(role, shard)
					next if pool_config.nil? || pool_config == writing

					@shared_pool_configs << [manager, role, shard, pool_config]
					manager.set_pool_config(role, shard, writing)
				end
			end
		end
	end

	# As ActiveRecord::TestDatabases does for Rails' parallel tests, without
	# requiring its parallelization, which loads DRb. Fixtures empty the tables
	# rather than Rails, so they can keep the ones they can reuse.
	private def create_databases(slot)
		verbose = ENV["VERBOSE"]
		skip_truncate = ENV["SKIP_TEST_DATABASE_TRUNCATE"]
		ENV["VERBOSE"] = "false"
		ENV["SKIP_TEST_DATABASE_TRUNCATE"] = "true"

		ActiveRecord::Base.configurations.configs_for(env_name: ActiveRecord::ConnectionHandling::DEFAULT_ENV.call, include_hidden: true).each do |db_config|
			db_config._database = "#{db_config.database}_#{slot}"
			next unless db_config.database_tasks?

			ActiveRecord::Tasks::DatabaseTasks.reconstruct_from_schema(db_config)
			ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(db_config) { |connection| Fixtures.prepare(connection, empty: !skip_truncate) }
		end
	ensure
		ActiveRecord::Base.establish_connection
		ENV["VERBOSE"] = verbose
		ENV["SKIP_TEST_DATABASE_TRUNCATE"] = skip_truncate
	end

	private def count_events
		ActiveSupport::Notifications.monotonic_subscribe("sql.active_record") do |_name, started, finished, _id, payload|
			next if payload[:cached] || (payload[:name] in "SCHEMA" | "TRANSACTION")

			Quickdraw::Counters.add("queries", finished - started)
		end

		ActiveSupport::Notifications.monotonic_subscribe("factory_bot.run_factory") do |_name, started, finished|
			Quickdraw::Counters.add("factories", finished - started)
		end
	end
end
