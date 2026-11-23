# frozen_string_literal: true

require "fileutils"
require "json"
require "openssl"
require "tmpdir"
require "active_support/testing/time_helpers"

# Fixtures, as Rails' transactional fixtures: each set loads once into each
# worker's databases, committed, and tests see it through their transactions.
# The quickdraw_fixtures table records each set a database holds, with a digest
# of its files (ERB rendered), so a later run keeps the sets whose files are
# unchanged rather than loading them again. A schema change empties the
# database, table and all.
#
# The loader renders the sets config wants before its workers fork (see
# #render), so their ERB renders once for them all, with the same times and
# random values, and can't tell one worker from another.
#
# A worker's databases keep every set loaded into them, so a test may see
# fixtures it didn't ask for, as in Rails.
module Quickdraw::Rails::Fixtures
	extend self

	TABLE = "quickdraw_fixtures"
	LOCK_BATCH = 25
	TIMESTAMP_COLUMNS = ["created_at", "created_on", "updated_at", "updated_on"].freeze

	# A set loaded into the database named `database` (in database.yml).
	# `tables` maps each table it fills to its row count, the timestamp columns
	# Rails filled in, at `loaded_at`, and the tables its foreign keys refer to.
	Entry = Data.define(:database, :digest, :loaded_at, :tables)

	@paths = []
	@wanted = []
	@loaded = {}
	@sets = {}
	@shared = {}
	@digests = {}
	@rerendering = []
	@references = {}
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
		rerender(@rerendering)
		load(@wanted)
		# Kept from #prepare, for this pass only: ERB may render differently later.
		@digests.clear
	end

	# In the loader, before a run's workers fork: renders the wanted sets' ERB
	# into a directory of plain YAML, which its workers read instead, and digests
	# them. A set a test class wants later renders in its worker, as does one
	# that can't render here, such as one whose ERB needs the database, which is
	# a worker's.
	def render
		FileUtils.rm_rf(@rendered) if @rendered
		@shared = {}
		return if @wanted.empty?

		@rendered = Dir.mktmpdir("quickdraw-fixtures-", Quickdraw.temporary_directory)
		@rendered_directories = "{#{@paths.each_index.map { |index| File.join(@rendered, index.to_s) }.join(',')}}"
		loader = Process.pid
		@removing ||= at_exit { FileUtils.rm_rf(@rendered) if Process.pid == loader }

		without_database do
			@wanted.each do |name|
				sources = sources(name)
				sources.each { |file, source| write(file, source) }
				@shared[name] = digest_of(sources)
			rescue StandardError, ScriptError
				# Its worker reports what's wrong, if anything is.
				nil
			end
		end
	end

	# Beside the other rendered files as `file` is beside the other fixture files.
	private def write(file, source)
		index = @paths.index { |path| file.start_with?("#{path}/") }
		rendered = File.join(@rendered, index.to_s, file.delete_prefix("#{@paths.fetch(index)}/"))
		FileUtils.mkdir_p(File.dirname(rendered))
		# Rails renders it as ERB again, which leaves it as it is.
		File.write(rendered, source.gsub("<%", "<%%"))
	end

	# With no connection to the loader's databases, so using one fails.
	private def without_database
		handler = ActiveRecord::Base.connection_handler
		ActiveRecord::Base.connection_handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
		yield
	ensure
		ActiveRecord::Base.connection_handler = handler
	end

	# For each database as a worker starts: keeps the sets whose rows are as
	# recorded, with the timestamps Rails filled in moved to now, and empties
	# every other table unless `empty` is false. A kept set whose files render
	# differently, as ERB with times or random values does on every run, is
	# rendered again when the worker starts (see #rerender).
	def prepare(connection, empty:)
		now = Time.at(Time.now.to_i)
		entries = recorded(connection)
		kept = intact(connection, entries)
		kept = kept.reject { |_name, entry| redated?(connection, entry, now) }
		kept = kept.select { |name, entry| present?(name) && (entry.digest == digest(name) || upserts?(connection)) }
		kept = independent(kept, entries.except(*kept.keys)) if empty
		rerendering = kept.keys.reject { |name| kept[name].digest == digest(name) }
		@rerendering.concat(rerendering)
		# For #load, which may find no connection to this database later.
		kept.each_value { |entry| entry.tables.each_key { |table| references(entry.database, table) } }

		if kept.empty?
			truncate(connection, connection.tables) if empty
			return
		end

		pool = connection.pool
		emptied = connection.tables - kept.values.flat_map { |entry| entry.tables.keys } - [pool.schema_migration.table_name, pool.internal_metadata.table_name, TABLE]
		emptied = with_rows(connection, emptied) if empty
		stale = entries.keys - kept.keys

		connection.transaction do
			connection.disable_referential_integrity { emptied.each { |table| connection.delete("DELETE FROM #{connection.quote_table_name(table)}") } } if empty && emptied.any?
			connection.delete("DELETE FROM #{TABLE} WHERE name IN #{list(connection, stale)}") if stale.any?
			@loaded.merge!(kept, refresh(connection, kept.except(*rerendering), now))
		end
	end

	# Of `tables`, those with rows. It looks at a few at a time, since each
	# statement holds a lock on every table and index it touches, and
	# PostgreSQL's lock table is shared by all workers starting at once.
	private def with_rows(connection, tables)
		tables.each_slice(LOCK_BATCH).flat_map do |batch|
			queries = batch.map { |table| "CASE WHEN EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)}) THEN 1 ELSE 0 END" }
			counts = connection.select_rows("SELECT #{queries.join(', ')}").first
			batch.zip(counts).filter_map { |table, count| table if Integer(count) == 1 }
		end
	end

	# Empties the tables that have rows, with any that refer to them, which the
	# database requires to be emptied with them. A database loaded from the schema
	# has no rows to empty.
	private def truncate(connection, tables)
		filled = with_rows(connection, tables)
		return if filled.empty?

		references = (tables - filled).to_h { |table| [table, connection.foreign_keys(table).map(&:to_table)] }

		loop do
			referring = references.select { |_table, to| to.intersect?(filled) }.keys
			break if referring.empty?

			filled += referring
			references = references.except(*referring)
		end

		connection.truncate_tables(*filled)
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

	# From the files the loader rendered, if it did (see #render).
	private def build(name)
		ActiveRecord::FixtureSet.new(nil, name, nil, "#{@shared.key?(name) ? @rendered_directories : @directories}/#{name}")
	end

	private def present?(name) = @shared.key?(name) || files(name).any?

	# By table name, which is a symbol for a set with no model, as recorded.
	private def rows_at(set, loaded_at) = travel_to(loaded_at) { set.table_rows }.transform_keys(&:to_s)

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
				rows[name] = rows_at(sets[name], loaded_at)
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

	# Renders the sets again and writes their rows over the ones they had, by
	# primary key, rather than emptying their tables, which would empty the
	# tables of every set that refers to them too. A set whose rows don't line up
	# with the ones it had loads again. A table whose rows have no primary key,
	# or leave it to the database, is emptied and filled instead, which nothing
	# else is emptied for.
	private def rerender(names)
		return if names.empty?

		loaded_at = Time.at(Time.now.to_i)
		sets = names.to_h { |name| [name, build(name)] }
		rows = sets.to_h { |name, set| [name, rows_at(set, loaded_at)] }

		sets.group_by { |_name, set| set.model_class&.connection_pool || ActiveRecord::Base.connection_pool }.each do |pool, pool_sets|
			pool.with_connection do |connection|
				entries = entries(connection, pool_sets.to_h, rows, loaded_at)
				aligned, misaligned = entries.partition { |name, entry| aligned?(connection, name, entry, rows.fetch(name)) }.map(&:to_h)

				begin
					connection.transaction(requires_new: true) { overwrite(connection, aligned, rows) } if aligned.any?
					@loaded.merge!(aligned)
				# Loading them again reports what's wrong with them, if anything is.
				rescue Misaligned, ActiveRecord::StatementInvalid
					misaligned.merge!(aligned)
				end

				discard(connection, misaligned.keys)
			end
		end

		sets.each { |name, set| @sets[name] = set if @loaded.key?(name) }
		names.clear
	end

	Misaligned = Class.new(StandardError)

	# Writes each row over the one with its primary key, so each table must end
	# up with as many rows as it had. Rows without their key replace their table's.
	private def overwrite(connection, entries, rows)
		rows_by_table = Hash.new { |hash, table| hash[table] = [] }
		entries.each_key { |name| rows.fetch(name).each { |table, table_rows| rows_by_table[table].concat(table_rows) } }
		keyed = rows_by_table.keys.select { |table| keyed?(connection, table, rows_by_table[table]) }
		before = row_counts(connection, keyed)

		statements = rows_by_table.flat_map do |table, table_rows|
			inserting = (connection.__send__(:build_fixture_sql, table_rows, table) if table_rows.any?)
			next ["DELETE FROM #{connection.quote_table_name(table)}", *inserting] unless keyed.include?(table)
			next [] unless inserting

			key = primary_key(connection, table)
			raise Misaligned unless table_rows.uniq { |row| key.map { |column| row.fetch(column) { row[column.to_sym] } } }.size == table_rows.size

			columns = connection.schema_cache.columns_hash(table).each_value.reject { |column| connection.supports_virtual_columns? && column.virtual? }.map(&:name)
			updates = (columns - key).map { |column| "#{connection.quote_column_name(column)} = excluded.#{connection.quote_column_name(column)}" }
			action = updates.empty? ? "NOTHING" : "UPDATE SET #{updates.join(', ')}"
			conflict = key.map { |column| connection.quote_column_name(column) }.join(", ")
			["#{inserting} ON CONFLICT (#{conflict}) DO #{action}"]
		end

		statements.each { |statement| connection.execute(statement) }

		if connection.respond_to?(:reset_pk_sequence!)
			(rows_by_table.keys - keyed).each { |table| connection.reset_pk_sequence!(table) if primary_key(connection, table).any? }
		end

		raise Misaligned unless row_counts(connection, keyed) == before

		check_foreign_keys(connection) unless enforces_foreign_keys?(connection)
		record(connection, entries)
	end

	# Empties the sets' tables, and those of the sets that depend on them, as
	# #prepare does a stale set's, so #load loads the ones tests want again.
	private def discard(connection, names)
		return if names.empty?

		database = connection.pool.db_config.name
		stale = @loaded.slice(*names)
		others = @loaded.select { |name, entry| entry.database == database && !stale.key?(name) }
		dropped = others.except(*independent(others, stale).keys).merge(stale)
		tables = dropped.each_value.flat_map { |entry| entry.tables.keys }.uniq & connection.tables

		connection.transaction do
			connection.disable_referential_integrity { tables.each { |table| connection.delete("DELETE FROM #{connection.quote_table_name(table)}") } }
			connection.delete("DELETE FROM #{TABLE} WHERE name IN #{list(connection, dropped.keys)}")
		end

		dropped.each_key { |name| @loaded.delete(name) }
	end

	# Whether #overwrite can write the set's rows over the ones it had: as many
	# rows with their keys as each table had. Rows without replace their table's,
	# so no other set can fill it or refer to it.
	private def aligned?(connection, name, entry, rows)
		had = @loaded.fetch(name).tables
		return false unless had.keys.sort == rows.keys.sort

		rows.all? do |table, table_rows|
			if keyed?(connection, table, table_rows)
				had.fetch(table).first == table_rows.size
			else
				@loaded.none? { |other, loaded| other != name && loaded.database == entry.database && dependent?(loaded, [table]) }
			end
		end
	end

	# Whether every row has its primary key, which a table may not have, and a
	# set with no model may leave to the database.
	private def keyed?(connection, table, rows)
		key = primary_key(connection, table)
		key.any? && rows.all? { |row| key.all? { |column| row.key?(column) || row.key?(column.to_sym) } }
	end

	private def primary_key(connection, table) = Array(connection.schema_cache.primary_keys(table))

	# Whether the database can write a row over the one with its key, as #overwrite does.
	private def upserts?(connection) = connection.supports_insert_conflict_target?

	# Whether the database is known to check foreign keys as rows are written.
	private def enforces_foreign_keys?(connection)
		connection.adapter_name == "SQLite" && connection.select_value("PRAGMA foreign_keys") == 1
	end

	private def insert(connection, sets, rows, loaded_at)
		entries = entries(connection, sets, rows, loaded_at)
		rows_by_table = Hash.new { |hash, table| hash[table] = [] }
		sets.each_key { |name| rows.fetch(name).each { |table, table_rows| rows_by_table[table].concat(table_rows) } }

		connection.transaction do
			connection.insert_fixtures_set(rows_by_table, rows_by_table.keys)
			check_foreign_keys(connection)

			if connection.respond_to?(:reset_pk_sequence!)
				sets.each_value { |set| connection.reset_pk_sequence!(set.table_name) }
			end

			record(connection, entries)
		end

		@loaded.merge!(entries)
	end

	private def entries(connection, sets, rows, loaded_at)
		database = connection.pool.db_config.name

		sets.to_h do |name, _set|
			tables = rows.fetch(name).to_h do |table, table_rows|
				filled = TIMESTAMP_COLUMNS.select { |column| table_rows.any? { |row| row[column] == loaded_at } }
				[table, [table_rows.size, filled, references(database, table)]]
			end

			[name, Entry.new(database:, digest: digest(name), loaded_at: loaded_at.iso8601, tables:)]
		end
	end

	private def check_foreign_keys(connection)
		return unless ActiveRecord.verify_foreign_keys_for_fixtures

		connection.check_all_foreign_keys_valid!
	rescue ActiveRecord::StatementInvalid => error
		raise "Foreign key violations found in your fixture data. Ensure you aren’t referring to labels that don’t exist on associations. Error from database:\n\n#{error.message}"
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
			tables = JSON.parse(tables)
			# As recorded, which a schema change would have emptied the database of.
			tables.each { |table, (_, _, to)| @references[[database, table]] ||= to if to }
			[name, Entry.new(database:, digest:, loaded_at:, tables:)]
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
		@references[[database, table]] ||= begin
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

		counts = row_counts(connection, expected.keys & connection.tables)
		entries.select { |_name, entry| entry.tables.keys.all? { |table| counts[table] == expected[table] } }
	end

	private def row_counts(connection, tables)
		tables.each_slice(LOCK_BATCH).flat_map do |batch|
			queries = batch.map { |table| "(SELECT COUNT(*) FROM #{connection.quote_table_name(table)})" }
			batch.zip(connection.select_rows("SELECT #{queries.join(', ')}").first.map { |count| Integer(count) })
		end.to_h
	end

	# Moves the times Rails filled in when the sets loaded to now, as if they had
	# just loaded. Dates are as they were (see #redated?).
	private def refresh(connection, entries, now)
		filled = entries.reject { |_name, entry| entry.tables.each_value.all? { |_, columns| columns.empty? } }
		return entries if filled.empty?

		statements = filled.each_value.flat_map do |entry|
			loaded_at = Time.iso8601(entry.loaded_at)

			entry.tables.flat_map do |table, (_, columns)|
				connection.schema_cache.columns_hash(table).each_value.filter_map do |column|
					next unless columns.include?(column.name) && column.type != :date

					quoted = connection.quote_column_name(column.name)
					"UPDATE #{connection.quote_table_name(table)} SET #{quoted} = #{connection.quote(now)} WHERE #{quoted} = #{connection.quote(loaded_at)}"
				end
			end
		end

		statements << "UPDATE #{TABLE} SET loaded_at = #{connection.quote(now.iso8601)} WHERE name IN #{list(connection, filled.keys)}"
		statements.each { |statement| connection.execute(statement) }
		entries.merge(filled.transform_values { |entry| entry.with(loaded_at: now.iso8601) })
	end

	# In Active Record's time zone, as it stores a time in a date column.
	private def date(time) = ((ActiveRecord.default_timezone == :utc) ? time.getutc : time.getlocal).to_date

	# The digest of the set's files, ERB rendered, so ERB that renders
	# differently (such as `<%= 1.day.ago %>`) renders the set again.
	private def digest(name) = @shared[name] || (@digests[name] ||= digest_of(sources(name)))

	private def digest_of(sources)
		digest = OpenSSL::Digest.new("SHA256")
		sources.each { |file, source| digest << file << "\0" << source << "\0" }
		digest.hexdigest
	end

	# Each of the set's files with its text, ERB rendered as Rails renders it.
	private def sources(name)
		files(name).to_h do |file|
			source = File.read(file)

			if source.include?("<%")
				erb = ERB.new(source)
				erb.filename = file
				source = erb.result(ActiveRecord::FixtureSet::RenderContext.create_subclass.new.get_binding)
			end

			[file, source]
		end
	end

	private def files(name) = Dir["#{@directories}/#{name}{.yml,/{**,*}/*.yml}"].select { |file| File.file?(file) }.sort

	private def travel_to(time, &)
		(@time_travel ||= Object.new.extend(ActiveSupport::Testing::TimeHelpers)).travel_to(time, &)
	end
end
