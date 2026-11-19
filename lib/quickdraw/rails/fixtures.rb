# frozen_string_literal: true

require "json"
require "openssl"
require "active_support/testing/time_helpers"

# Fixtures, as Rails' transactional fixtures: each set loads once into each
# worker's databases, committed, and tests see it through their transactions.
# The quickdraw_fixtures table records each set a database holds, with a digest
# of its files (ERB rendered), so a later run keeps the sets whose files are
# unchanged rather than loading them again. A schema change empties the
# database, table and all.
#
# A worker's databases keep every set loaded into them, so a test may see
# fixtures it didn't ask for, as in Rails.
module Quickdraw::Rails::Fixtures
	extend self

	TABLE = "quickdraw_fixtures"
	TIMESTAMP_COLUMNS = ["created_at", "created_on", "updated_at", "updated_on"].freeze

	# A set loaded into the database named `database` (in database.yml).
	# `tables` maps each table it fills to its row count and the timestamp
	# columns Rails filled in, at `loaded_at`.
	Entry = Data.define(:database, :digest, :loaded_at, :tables)

	@paths = []
	@wanted = []
	@loaded = {}
	@sets = {}
	@started = false

	# Extends Quickdraw::BasicTest, with `config.rails`.
	module Declarations
		# Loads fixture sets for the class's tests, with an accessor for each:
		# `fixtures :users` defines `users(:ada)`. `fixtures :all` loads every set.
		def fixtures(*names)
			include Records

			Quickdraw::Rails::Fixtures.want(names).each do |name|
				define_method(name.tr("/", "_")) { |*labels| fixture(name, *labels) }
			end
		end
	end

	module Records
		# The record for each label, found once per test, or with no labels, all
		# the set's records. One label returns one record.
		def fixture(name, *labels)
			records = (@fixture_records ||= {})

			found = (labels.empty? ? Quickdraw::Rails::Fixtures.labels(name) : labels).map do |label|
				label = label.to_s
				records[[name, label]] ||= Quickdraw::Rails::Fixtures.find(name, label)
			end

			(labels.size == 1) ? found.first : found
		end
	end

	# Absolute paths of the directories with fixture files.
	def paths=(paths)
		@paths = paths.freeze
		@directories = "{#{paths.join(',')}}"
	end

	# The set names, with :all as every set in the fixture paths. Loads any not
	# yet loaded, once the worker's databases are ready.
	def want(names)
		names = names.flatten.flat_map do |name|
			case name
			in :all then all
			in String | Symbol then name.to_s
			end
		end

		@wanted |= names
		load(names) if @started
		names
	end

	# As Rails does, except for file fixtures in files/.
	private def all
		@all ||= @paths.flat_map do |path|
			Dir[File.join(path, "{**,*}/*.yml")].filter_map do |file|
				name = file.delete_prefix("#{path}/").delete_suffix(".yml")
				name unless name.start_with?("files/")
			end
		end.uniq.sort.freeze
	end

	# Once the worker's databases are prepared.
	def start
		@started = true
		load(@wanted)
	end

	# For each database as a worker starts: keeps the sets whose files and rows
	# are as recorded, with the timestamps Rails filled in moved to now, and
	# empties every other table unless `empty` is false.
	def prepare(connection, empty:)
		now = Time.at(Time.now.to_i)
		entries = recorded(connection)
		kept = intact(connection, entries.select { |name, entry| entry.digest == digest(name) })
		kept = kept.reject { |_name, entry| redated?(connection, entry, now) }
		kept = independent(kept, entries.except(*kept.keys)) if empty

		if kept.empty?
			connection.truncate_tables(*connection.tables) if empty
			return
		end

		pool = connection.pool
		emptied = connection.tables - kept.values.flat_map { |entry| entry.tables.keys } - [pool.schema_migration.table_name, pool.internal_metadata.table_name, TABLE]
		stale = entries.keys - kept.keys

		connection.transaction do
			connection.disable_referential_integrity { emptied.each { |table| connection.delete("DELETE FROM #{connection.quote_table_name(table)}") } } if empty
			connection.delete("DELETE FROM #{TABLE} WHERE name IN #{list(connection, stale)}") if stale.any?
			@loaded.merge!(refresh(connection, kept, now))
		end
	end

	# After a test committed, which may have changed them.
	def reload
		names = @loaded.keys
		@loaded.clear
		@sets.clear
		load(names)
	end

	def labels(name) = set(name).fixtures.keys

	def find(name, label)
		fixture = set(name)[label] or raise ::ArgumentError, "There’s no #{label} fixture in #{name}."
		fixture.find
	end

	private def set(name)
		@sets[name] ||= build(name).tap(&:table_rows)
	end

	private def build(name)
		ActiveRecord::FixtureSet.new(nil, name, nil, "#{@directories}/#{name}")
	end

	private def load(names)
		names = names.reject { |name| @loaded.key?(name) }
		return if names.empty?

		loaded_at = Time.at(Time.now.to_i)
		sets = {}
		rows = {}

		# Loading a set empties its tables, so the sets sharing or referring to one
		# (see #independent) load with it.
		until names.empty?
			names.each do |name|
				sets[name] = build(name)
				rows[name] = travel_to(loaded_at) { sets[name].table_rows }
			end

			tables = rows.values.flat_map(&:keys)
			names = @loaded.filter_map { |name, entry| name if !sets.key?(name) && dependent?(entry, tables) }
		end

		sets.group_by { |_name, set| set.model_class&.connection_pool || ActiveRecord::Base.connection_pool }.each do |pool, pool_sets|
			pool.with_connection do |connection|
				insert(connection, pool_sets.to_h, rows, loaded_at)
			end
		end

		@sets.merge!(sets)
	end

	private def insert(connection, sets, rows, loaded_at)
		rows_by_table = Hash.new { |hash, table| hash[table] = [] }
		entries = {}

		sets.each_key do |name|
			tables = rows.fetch(name).to_h do |table, table_rows|
				rows_by_table[table].concat(table_rows)
				filled = TIMESTAMP_COLUMNS.select { |column| table_rows.any? { |row| row[column] == loaded_at } }
				[table, [table_rows.size, filled]]
			end

			entries[name] = Entry.new(database: connection.pool.db_config.name, digest: digest(name), loaded_at: loaded_at.iso8601, tables:)
		end

		connection.transaction do
			connection.insert_fixtures_set(rows_by_table, rows_by_table.keys)

			if ActiveRecord.verify_foreign_keys_for_fixtures
				begin
					connection.check_all_foreign_keys_valid!
				rescue ActiveRecord::StatementInvalid => error
					raise "Foreign key violations found in your fixture data. Ensure you aren’t referring to labels that don’t exist on associations. Error from database:\n\n#{error.message}"
				end
			end

			if connection.respond_to?(:reset_pk_sequence!)
				sets.each_value { |set| connection.reset_pk_sequence!(set.table_name) }
			end

			record(connection, entries)
		end

		@loaded.merge!(entries)
	end

	private def record(connection, entries)
		connection.create_table(TABLE, id: false, if_not_exists: true) do |table|
			table.string :name, null: false
			table.string :digest, null: false
			table.string :loaded_at, null: false
			table.text :tables, null: false
		end

		connection.delete("DELETE FROM #{TABLE} WHERE name IN #{list(connection, entries.keys)}")
		values = entries.map { |name, entry| list(connection, [name, entry.digest, entry.loaded_at, JSON.generate(entry.tables)]) }
		connection.insert("INSERT INTO #{TABLE} (name, digest, loaded_at, tables) VALUES #{values.join(', ')}")
	end

	private def list(connection, values)
		"(#{values.map { |value| connection.quote(value) }.join(', ')})"
	end

	private def recorded(connection)
		return {} unless connection.table_exists?(TABLE)

		database = connection.pool.db_config.name

		connection.select_rows("SELECT name, digest, loaded_at, tables FROM #{TABLE}").to_h do |name, digest, loaded_at, tables|
			[name, Entry.new(database:, digest:, loaded_at:, tables: JSON.parse(tables))]
		end
	end

	# Without the sets that refer to a stale set's tables, which are about to be
	# emptied, since deleting from them can cascade to theirs: SQLite can't turn
	# foreign keys off in a transaction, nor PostgreSQL without the privilege.
	private def independent(kept, stale)
		emptied = stale.values.flat_map { |entry| entry.tables.keys }

		loop do
			dependent = kept.select { |_name, entry| dependent?(entry, emptied) }
			return kept if dependent.empty?

			emptied += dependent.values.flat_map { |entry| entry.tables.keys }
			kept = kept.except(*dependent.keys)
		end
	end

	# Whether the set shares a table with `tables`, or has foreign keys to one.
	private def dependent?(entry, tables)
		entry.tables.each_key.any? { |table| tables.include?(table) || references(entry.database, table).intersect?(tables) }
	end

	private def references(database, table)
		(@references ||= {})[[database, table]] ||= begin
			pool = ActiveRecord::Base.connection_handler.connection_pool_list(ActiveRecord.writing_role).find { |it| it.db_config.name == database }
			raise "There’s no connection to the #{database} database." unless pool

			pool.with_connection { |connection| connection.foreign_keys(table).map(&:to_table) }
		end
	end

	# Whether Rails filled in a date column on a day before today. Moving those
	# to today could move dates the fixtures set to the same day too.
	private def redated?(connection, entry, now)
		return false if date(Time.iso8601(entry.loaded_at)) == date(now)

		entry.tables.any? do |table, (_, filled)|
			columns = connection.schema_cache.columns_hash(table)
			filled.any? { |column| columns[column]&.type == :date }
		end
	end

	# Without the sets whose tables don't have the rows they were loaded with,
	# such as after something committed to them.
	private def intact(connection, entries)
		expected = Hash.new(0)
		entries.each_value { |entry| entry.tables.each { |table, (count, _)| expected[table] += count } }
		return entries if expected.empty?

		tables = expected.keys & connection.tables
		return {} if tables.empty?

		queries = tables.map { |table| "(SELECT COUNT(*) FROM #{connection.quote_table_name(table)})" }
		counts = tables.zip(connection.select_rows("SELECT #{queries.join(', ')}").first.map { |count| Integer(count) }).to_h
		entries.select { |_name, entry| entry.tables.keys.all? { |table| counts[table] == expected[table] } }
	end

	# Moves the times Rails filled in when the sets loaded to now, as if they had
	# just loaded. Dates are as they were (see #redated?).
	private def refresh(connection, entries, now)
		entries.to_h do |name, entry|
			next [name, entry] if entry.tables.each_value.all? { |_, filled| filled.empty? }

			loaded_at = Time.iso8601(entry.loaded_at)

			entry.tables.each do |table, (_, filled)|
				connection.schema_cache.columns_hash(table).each_value do |column|
					next unless filled.include?(column.name) && column.type != :date

					quoted = connection.quote_column_name(column.name)
					connection.update("UPDATE #{connection.quote_table_name(table)} SET #{quoted} = #{connection.quote(now)} WHERE #{quoted} = #{connection.quote(loaded_at)}")
				end
			end

			connection.update("UPDATE #{TABLE} SET loaded_at = #{connection.quote(now.iso8601)} WHERE name = #{connection.quote(name)}")
			[name, entry.with(loaded_at: now.iso8601)]
		end
	end

	# In Active Record's time zone, as it stores a time in a date column.
	private def date(time) = ((ActiveRecord.default_timezone == :utc) ? time.getutc : time.getlocal).to_date

	# The digest of the set's files, ERB rendered, so ERB that renders
	# differently (such as `<%= 1.day.ago %>`) loads the set again.
	private def digest(name)
		digest = OpenSSL::Digest.new("SHA256")

		Dir["#{@directories}/#{name}{.yml,/{**,*}/*.yml}"].select { |file| File.file?(file) }.sort.each do |file|
			source = File.read(file)
			if source.include?("<%")
				erb = ERB.new(source)
				erb.filename = file
				source = erb.result(ActiveRecord::FixtureSet::RenderContext.create_subclass.new.get_binding)
			end

			digest << file << "\0" << source << "\0"
		end

		digest.hexdigest
	end

	private def travel_to(time, &)
		(@time_travel ||= Object.new.extend(ActiveSupport::Testing::TimeHelpers)).travel_to(time, &)
	end
end
