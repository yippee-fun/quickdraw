# frozen_string_literal: true

require "openssl"

# For PostgreSQL, in place of loading fixtures into each worker's databases
# (see Fixtures): a template database for each of the app's holds its schema
# and every fixture set, and each worker's databases are copies of them, which
# PostgreSQL makes file by file.
#
# A template is named for a digest of the schema files, the fixture files as
# written, and VERSION. The loader builds any that are missing before its
# workers fork, and drops those with other digests. Nothing connects to a
# template once it's built, and nothing changes it, so it keeps what its ERB
# rendered when it was built.
#
# Each worker database's comment says which digest it was copied from and
# whether it's clean. A worker keeps a clean copy with its digest, and replaces
# any other. The comment says "dirty" while a worker runs, so a worker that
# dies leaves a database the next will replace, and "clean" once it exits with
# every test rolled back. A test that commits has its worker's databases
# replaced right away. A worker holds a lock on its databases while it runs,
# so another run's worker in the same slot fails rather than dropping them.
#
# Dropping a database that has connections needs PostgreSQL 13 or later.
module Quickdraw::Rails::Templates
	extend self

	# Part of every digest. Change it when templates are built differently.
	VERSION = 1
	# PostgreSQL cuts longer names short.
	NAME_LIMIT = 63
	# 13, for DROP DATABASE … WITH (FORCE).
	MINIMUM_VERSION = 130000

	@provided = {}
	@claims = []
	@clean = false

	# Whether every database the app's tasks manage is on PostgreSQL 13 or later.
	def apply?
		managed.any? && managed.all? { |db_config| db_config.adapter == "postgresql" && version(db_config) >= MINIMUM_VERSION }
	end

	# In the loader, with no connections of its own open: builds the templates
	# unless they're all there, holding each database's lock, so runs starting
	# together build them once.
	def build(fixture_paths, fixture_names)
		@digest = digest(fixture_paths)
		maintenance = managed.to_h { |db_config| [db_config, maintain(db_config)] }
		maintenance.each { |db_config, connection| lock(connection, db_config.database, "pg_advisory_lock") }
		construct(maintenance, fixture_paths, fixture_names) unless maintenance.all? { |db_config, connection| exists?(connection, template(db_config.database)) }

		maintenance.each do |db_config, connection|
			stale = connection.select_values("SELECT datname FROM pg_database").select { |name| name.start_with?(template_prefix(db_config.database)) }
			(stale - [template(db_config.database)]).each { |name| drop(connection, name) }
		end
	ensure
		maintenance&.each_value(&:disconnect!)
	end

	# In a worker, for `db_config`, already named for the worker's slot: keeps
	# its database if it's a clean copy of the template of `database`, and
	# copies the template over it otherwise.
	def provide(db_config, database)
		claim(db_config)

		maintaining(db_config, database) do |connection|
			copy(connection, template(database), db_config.database) unless comment(connection, db_config.database) == stamp("clean")
			mark(connection, db_config.database, "dirty")
		end

		@provided[db_config] = database
		@clean = true
	end

	# Before a test that commits, so its worker's databases are replaced if it
	# never gets to (see #restore).
	def dirty = @clean = false

	# After a test committed: copies the templates over the worker's databases.
	def restore
		@clean = false
		ActiveRecord::Base.connection_handler.clear_all_connections!

		@provided.each do |db_config, database|
			maintaining(db_config, database) do |connection|
				copy(connection, template(database), db_config.database)
				mark(connection, db_config.database, "dirty")
			end
		end

		@clean = true
	end

	# As a worker exits, having rolled back or restored after every test.
	def release
		return unless @clean

		@provided.each do |db_config, database|
			maintaining(db_config, database) { |connection| mark(connection, db_config.database, "clean") }
		end
	end

	private def version(db_config)
		connection = maintain(db_config)
		connection.database_version
	ensure
		connection&.disconnect!
	end

	# Locks the worker's database until the worker exits, or raises if another
	# run's worker holds it.
	private def claim(db_config)
		connection = maintain(db_config)
		claimed = connection.select_value("SELECT pg_try_advisory_lock(hashtext('quickdraw worker'), hashtext(#{connection.quote(db_config.database)}))::int") == 1

		unless claimed
			connection.disconnect!
			raise "Another Quickdraw run is using the #{db_config.database} database. Wait for it to finish."
		end

		@claims << connection
	end

	private def managed
		ActiveRecord::Base.configurations.configs_for(env_name: ActiveRecord::ConnectionHandling::DEFAULT_ENV.call, include_hidden: true).select(&:database_tasks?)
	end

	private def digest(fixture_paths)
		digest = OpenSSL::Digest.new("SHA256")
		digest << VERSION.to_s

		managed.each do |db_config|
			file = ActiveRecord::Tasks::DatabaseTasks.schema_dump_path(db_config)
			digest << "\0" << db_config.name << "\0" << ((file && File.exist?(file)) ? File.read(file) : "")
		end

		fixture_paths.each do |path|
			# With every file beside the sets, file fixtures included, which their ERB
			# may read.
			Dir[File.join(path, "{**,*}/*")].uniq.sort.each do |file|
				name = file.delete_prefix("#{path}/")
				digest << "\0" << name << "\0" << File.read(file) if File.file?(file)
			end
		end

		digest.hexdigest[0, 16]
	end

	# Each schema loads into a database beside its template, which takes the
	# template's name once every one is built, so a template is always whole.
	private def construct(maintenance, fixture_paths, fixture_names)
		maintenance.each do |db_config, connection|
			raise "#{template(db_config.database)} is too long a name for a PostgreSQL database. Shorten the name of #{db_config.database}." if template(db_config.database).bytesize > NAME_LIMIT

			drop(connection, building(db_config.database))
		end

		in_fork { fill(maintenance.keys, fixture_paths, fixture_names) }

		maintenance.each do |db_config, connection|
			template = connection.quote_table_name(template(db_config.database))
			drop(connection, template(db_config.database))
			connection.execute("ALTER DATABASE #{connection.quote_table_name(building(db_config.database))} ALLOW_CONNECTIONS false")
			connection.execute("ALTER DATABASE #{connection.quote_table_name(building(db_config.database))} RENAME TO #{template}")
		end
	end

	private def fill(db_configs, fixture_paths, fixture_names)
		databases = db_configs.to_h { |db_config| [db_config, db_config.database] }

		db_configs.each do |db_config|
			db_config._database = building(db_config.database)
			ActiveRecord::Tasks::DatabaseTasks.reconstruct_from_schema(db_config)
		end

		ActiveRecord::Base.establish_connection
		ActiveRecord::FixtureSet.create_fixtures(fixture_paths, fixture_names) if fixture_names.any?
	ensure
		ActiveRecord::FixtureSet.reset_cache
		ActiveRecord::Base.connection_handler.clear_all_connections!
		databases.each { |db_config, database| db_config._database = database }
		ActiveRecord::Base.establish_connection
	end

	# Where there are forks, so the models and columns the fixtures load, which a
	# later schema may change, aren't the loader's for its workers to inherit.
	private def in_fork
		return yield unless Process.respond_to?(:fork)

		reader, writer = IO.pipe

		pid = Process.fork do
			reader.close
			yield
		rescue Exception => error
			writer.write("#{error.class}: #{error.message}")
		ensure
			exit!(error ? 1 : 0)
		end

		writer.close
		failure = reader.read
		Process.wait(pid)
		raise "Quickdraw couldn’t build the template databases. #{failure}" unless $?.success?
	ensure
		reader&.close
	end

	private def building(database) = "#{template_prefix(database)}building"

	private def template(database) = "#{template_prefix(database)}#{@digest}"
	private def template_prefix(database) = "#{database}_qd_template_"

	# A connection to the server's own database, from which it makes and drops
	# the others.
	private def maintain(db_config)
		db_config.adapter_class.new(db_config.configuration_hash.merge(database: "postgres", schema_search_path: "public"))
	end

	# Holding the lock of `database` with every other worker, but not with a
	# loader that's building or dropping its templates.
	private def maintaining(db_config, database)
		connection = maintain(db_config)
		lock(connection, database, "pg_advisory_lock_shared")
		yield connection
	ensure
		connection&.disconnect!
	end

	# Until the connection closes.
	private def lock(connection, database, function)
		connection.execute("SELECT #{function}(hashtext('quickdraw'), hashtext(#{connection.quote(database)}))")
	end

	private def exists?(connection, database)
		connection.select_value("SELECT 1 FROM pg_database WHERE datname = #{connection.quote(database)}") == 1
	end

	private def drop(connection, database)
		connection.execute("DROP DATABASE IF EXISTS #{connection.quote_table_name(database)} WITH (FORCE)")
	end

	private def copy(connection, template, database)
		raise "The #{template} database has gone, which another run with different fixtures or schema drops. Run the tests again." unless exists?(connection, template)

		drop(connection, database)
		connection.execute("CREATE DATABASE #{connection.quote_table_name(database)} TEMPLATE #{connection.quote_table_name(template)}")
	end

	private def comment(connection, database)
		connection.select_value("SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = #{connection.quote(database)}")
	end

	private def mark(connection, database, state)
		connection.execute("COMMENT ON DATABASE #{connection.quote_table_name(database)} IS #{connection.quote(stamp(state))}")
	end

	private def stamp(state) = "Quickdraw #{@digest} #{state}"
end
