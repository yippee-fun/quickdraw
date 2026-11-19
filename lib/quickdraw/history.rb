# frozen_string_literal: true

# Run history in SQLite. Only ever loaded in the coordinator after the loaders
# have forked, or in a throwaway fork, so neither sqlite3 nor json reaches the
# processes that run tests.
#
# The database is a cache: a schema change or corruption rebuilds it rather
# than migrating or repairing, and old runs and tests are pruned.
class Quickdraw::History
	# Raised when the history can't be opened or saved. Tests still run without it.
	class Error < StandardError
		# SQLite's messages continue with the SQL on further lines.
		def initialize(message)
			super(message.lines.first.to_s.chomp.delete_suffix(":"))
		end
	end

	TABLES = ["runs", "tests", "results", "files"].freeze

	SCHEMA_VERSION = 7
	KEPT_RUNS = 100

	# Weight of the latest run in each test's rolling average duration.
	SMOOTHING = 0.3

	# Rows per INSERT statement. Executing one statement per row from Ruby costs
	# far more than SQLite's own work.
	BATCH_SIZE = 500

	PRAGMAS = {
		"journal_mode" => "WAL",
		# In WAL mode, NORMAL can lose the latest run on power loss but can't
		# corrupt the database. OFF can, and benchmarks no faster here.
		"synchronous" => "NORMAL",
		"temp_store" => "MEMORY",
		"cache_size" => -32_000,
		"mmap_size" => 268_435_456,
		"journal_size_limit" => 67_108_864,
		# Stops a large run from checkpointing in the middle of its commit. SQLite
		# still checkpoints when the connection closes, and we checkpoint on open.
		"wal_autocheckpoint" => 0,
		# Keeps ANALYZE quick by sampling. The statistics let per-test queries use
		# a skip-scan of the results primary key, so it needs no second index.
		"analysis_limit" => 400,
	}.freeze

	SCHEMA = <<~SQL
		CREATE TABLE runs (
			id INTEGER PRIMARY KEY,
			started_at TEXT NOT NULL,
			finished_at TEXT NOT NULL,
			seed INTEGER NOT NULL,
			processes INTEGER NOT NULL,
			git_sha TEXT,
			git_branch TEXT,
			-- The commit, plus a hash of uncommitted changes when there are any, so
			-- runs of the same code can be compared.
			code TEXT,
			-- Set for the runs of one `quickdraw flaky` scan, from QUICKDRAW_SCAN.
			scan TEXT,
			duration REAL NOT NULL,
			tests INTEGER NOT NULL,
			failed INTEGER NOT NULL,
			errored INTEGER NOT NULL,
			passed INTEGER NOT NULL,
			-- What was asked for (the paths and --failed), so runs of the same
			-- selection can be compared when tuning the worker count.
			selection TEXT NOT NULL,
			-- How the worker count was chosen: manual, default, estimated, tuned or exploring.
			worker_choice TEXT NOT NULL,
			-- Totals across all tests, in seconds.
			test_time REAL NOT NULL,
			cpu_time REAL NOT NULL,
			longest_test REAL NOT NULL
		);

		CREATE INDEX runs_by_selection ON runs (selection, id);

		-- One row per test. key is a JSON array of path, class, description and the
		-- occurrence of that description in the file. Lines aren't part of the key
		-- (except for tests without a description), so editing a file doesn't lose
		-- the history of tests below the edit.
		CREATE TABLE tests (
			id INTEGER PRIMARY KEY,
			key TEXT NOT NULL UNIQUE,
			path TEXT NOT NULL,
			line INTEGER NOT NULL,
			class_name TEXT,
			description TEXT,
			average_duration REAL,
			runs INTEGER NOT NULL DEFAULT 0,
			failures INTEGER NOT NULL DEFAULT 0,
			last_status TEXT,
			last_run_id INTEGER
		);

		-- status: passed, failed, errored or crashed.
		-- Times are in seconds. setup, body and teardown are each phase's wall
		-- time; cpu, gc and allocations cover the whole test.
		-- worker numbers each worker process in the run (a replacement for a
		-- crashed worker gets a new number), and sequence is the test's position
		-- in that process's run order, for replaying order-dependent failures.
		-- details is JSON, {"failures": [...], "errors": [...]}, only for problems.
		CREATE TABLE results (
			run_id INTEGER NOT NULL,
			test_id INTEGER NOT NULL,
			status TEXT NOT NULL,
			duration REAL,
			setup REAL,
			body REAL,
			teardown REAL,
			cpu REAL,
			gc REAL,
			allocations INTEGER,
			assertions INTEGER,
			-- The worker process (each replacement gets a new one), its slot (its
			-- QUICKDRAW_WORKER number, which replacements share), and the test's
			-- position in the order that process ran tests.
			worker INTEGER NOT NULL,
			slot INTEGER NOT NULL,
			sequence INTEGER NOT NULL,
			details TEXT,
			PRIMARY KEY (run_id, test_id)
		) WITHOUT ROWID;

		-- Whether each file loaded the last time a run tried it.
		CREATE TABLE files (
			path TEXT PRIMARY KEY,
			load_error TEXT,
			last_run_id INTEGER NOT NULL
		) WITHOUT ROWID;
	SQL

	INSERT_RUN = <<~SQL
		INSERT INTO runs (
			started_at, finished_at, seed, processes, git_sha, git_branch, code, scan, duration, tests, failed, errored, passed,
			selection, worker_choice, test_time, cpu_time, longest_test
		)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	SQL

	CPU = Quickdraw::STATS.index("cpu")

	Run = Data.define(:processes, :duration, :worker_choice, :tests, :test_time)
	Expected = Data.define(:test_time, :tests, :longest_test)

	# An upsert, so a concurrent run that adds the same test doesn't conflict.
	UPSERT_TESTS = <<~SQL
		INSERT INTO tests (key, path, line, class_name, description) VALUES %s
		ON CONFLICT (key) DO UPDATE SET line = excluded.line
		RETURNING id, key
	SQL

	INSERT_RESULTS = "INSERT INTO results VALUES %s"

	UPSERT_FILES = <<~SQL
		INSERT INTO files (path, load_error, last_run_id) VALUES %s
		ON CONFLICT (path) DO UPDATE SET load_error = excluded.load_error, last_run_id = excluded.last_run_id
	SQL

	UPDATE_STATS = <<~SQL
		UPDATE tests SET
			average_duration = CASE
				WHEN results.duration IS NULL THEN tests.average_duration
				WHEN tests.average_duration IS NULL THEN results.duration
				ELSE tests.average_duration * (1 - :smoothing) + results.duration * :smoothing
			END,
			runs = tests.runs + 1,
			failures = tests.failures + (results.status IN ('failed', 'errored', 'crashed')),
			last_status = results.status,
			last_run_id = :run_id
		FROM results
		WHERE results.run_id = :run_id AND results.test_id = tests.id
	SQL

	Record = Data.define(:key, :path, :test, :result, :worker, :slot, :sequence)
	KnownTest = Data.define(:id, :path, :line, :average_duration)

	RunSummary = Data.define(:finished_at, :seed, :processes, :worker_choice, :git_sha, :git_branch, :duration, :tests, :failed, :errored, :passed)
	SlowTest = Data.define(:path, :line, :class_name, :description, :average_duration)
	FlakyTest = Data.define(:path, :line, :class_name, :description, :runs, :failures)
	OrderedTest = Data.define(:path, :line, :class_name, :description)
	Outcome = Data.define(:run_id, :test_id, :path, :line, :class_name, :description, :status, :seed)
	FailureOrder = Data.define(:run_id, :seed, :slot, :before, :test)

	FLAKY_TESTS = <<~SQL
		WITH recent AS (
			SELECT results.test_id, runs.code, results.status IN ('failed', 'errored', 'crashed') AS failed
			FROM results JOIN runs ON runs.id = results.run_id
			WHERE results.run_id IN (SELECT id FROM runs ORDER BY id DESC LIMIT ?)
				AND results.status IN ('passed', 'failed', 'errored', 'crashed')
		),
		-- Runs of the same code where a test both passed and failed. GROUP BY puts
		-- runs outside git together.
		flaky AS (
			SELECT test_id, COUNT(*) AS runs, SUM(failed) AS failures FROM recent
			GROUP BY test_id, code
			HAVING MIN(failed) = 0 AND MAX(failed) = 1
		)
		SELECT tests.path, tests.line, tests.class_name, tests.description, SUM(flaky.runs), SUM(flaky.failures) AS failures
		FROM flaky JOIN tests ON tests.id = flaky.test_id
		GROUP BY flaky.test_id
		ORDER BY failures DESC, tests.path, tests.line
	SQL

	# Read-only, it never creates, migrates or rebuilds the history, so looking
	# at it can't lose it. That's for reading only, as `quickdraw history` does.
	def initialize(path, read_only: false)
		require "sqlite3"
		require "json"
		require "fileutils"
		require "time"
		require "digest"

		@path = path

		if read_only
			@db = SQLite3::Database.new(path, readonly: true)
			@db.busy_timeout = 5000
			tables = @db.execute("SELECT name FROM sqlite_schema WHERE type = 'table'").flatten

			unless @db.get_first_value("PRAGMA user_version") == SCHEMA_VERSION && (TABLES - tables).empty?
				raise Error, "it was recorded by a different version of Quickdraw, and the next run will replace it"
			end
		else
			# git takes ~15ms, so it runs while the tests do.
			@revision = Thread.new { git_revision }
			FileUtils.mkdir_p(File.dirname(path))
			connect
		end
	rescue LoadError, SystemCallError, SQLite3::Exception => error
		raise Error, error.message
	end

	# The identity of each test in a file, in load order.
	def keys(path, tests)
		occurrences = Hash.new(0)

		tests.map do |test|
			name = test["description"] || "line #{test['line']}"
			occurrence = occurrences[[test["class_name"], name]] += 1
			JSON.generate(utf8([path, test["class_name"], name, occurrence]))
		end
	end

	# { key => average duration } for every test with a recorded duration.
	def average_durations
		@known.each_with_object({}) do |(key, test), durations|
			durations[key] = test.average_duration if test.average_duration
		end
	end

	# { path => total average duration of its tests }
	def file_durations
		@known.each_value.with_object(Hash.new(0.0)) do |test, durations|
			durations[test.path] += test.average_duration if test.average_duration
		end
	end

	# Expected total test time, number of tests, and longest test, for the known
	# tests in `paths`.
	def expected(paths)
		wanted = paths.to_h { |path| [path, true] }
		durations = @known.each_value.filter_map { |test| test.average_duration if wanted.key?(test.path) }
		Expected.new(test_time: durations.sum, tests: durations.size, longest_test: durations.max)
	end

	# The most recent runs of `selection` that ran any tests with forked workers,
	# newest first. Runs without fork had no choice of worker count.
	def recent_runs(selection, limit: 20)
		@db.execute(<<~SQL, [selection, limit]).map { |row| Run.new(*row) }
			SELECT processes, duration, worker_choice, tests, test_time FROM runs
			WHERE selection = ? AND tests > 0 AND worker_choice != 'default'
			ORDER BY id DESC LIMIT ?
		SQL
	rescue SQLite3::Exception => error
		raise Error, error.message
	end

	# The most recent run of `selection` that ran any tests, or nil.
	def last_run(selection)
		row = @db.get_first_row(<<~SQL, [selection])
			SELECT processes, duration, worker_choice, tests, test_time FROM runs
			WHERE selection = ? AND tests > 0
			ORDER BY id DESC LIMIT 1
		SQL

		Run.new(*row) if row
	rescue SQLite3::Exception => error
		raise Error, error.message
	end

	# The share of test time spent waiting rather than on the CPU in the most
	# recent run of `selection`, else of any selection, or nil.
	def last_waiting_share(selection)
		test_time, cpu_time = @db.get_first_row(<<~SQL, [selection])
			SELECT test_time, cpu_time FROM runs ORDER BY selection = ? DESC, id DESC LIMIT 1
		SQL

		(1 - (cpu_time / test_time)).clamp(0.0, 1.0) if test_time&.positive?
	rescue SQLite3::Exception => error
		raise Error, error.message
	end

	# [key, path] for every test whose most recent result was a failure, an
	# error or a crash. Skipped and pending tests aren't failing.
	def failing_tests
		@db.execute("SELECT key, path FROM tests WHERE last_status NOT IN ('passed', 'skipped', 'pending')")
	rescue SQLite3::Exception => error
		raise Error, error.message
	end

	# Paths of files that failed to load the last time a run tried them.
	def unloadable_files
		@db.execute("SELECT path FROM files WHERE load_error IS NOT NULL").flatten
	rescue SQLite3::Exception => error
		raise Error, error.message
	end

	# The most recent runs of any selection, newest first.
	def runs(limit:)
		@db.execute(<<~SQL, [limit]).map do |finished_at, seed, processes, worker_choice, git_sha, git_branch, duration, tests, failed, errored, passed|
			SELECT finished_at, seed, processes, worker_choice, git_sha, git_branch, duration, tests, failed, errored, passed
			FROM runs ORDER BY id DESC LIMIT ?
		SQL
			RunSummary.new(finished_at: Time.iso8601(finished_at), seed:, processes:, worker_choice:, git_sha:, git_branch:, duration:, tests:, failed:, errored:, passed: passed == 1)
		end
	rescue SQLite3::Exception => error
		raise Error, error.message
	end

	# The last run in which the test at `path:line` (or the nearest above it)
	# failed, with the tests its worker process ran before it, in order: what a
	# failure that depends on order depends on. Nil if it hasn't failed.
	def failure_order(path, line)
		# Every test on that line, since tests generated in a loop share one.
		run_id, worker, slot, sequence, seed = @db.get_first_row(<<~SQL, [path, path, line])
			SELECT results.run_id, results.worker, results.slot, results.sequence, runs.seed
			FROM results
				JOIN runs ON runs.id = results.run_id
				JOIN tests ON tests.id = results.test_id
			WHERE tests.path = ?
				AND tests.line = (SELECT max(line) FROM tests WHERE path = ? AND line <= ?)
				AND results.status IN ('failed', 'errored', 'crashed')
			ORDER BY results.run_id DESC LIMIT 1
		SQL
		return unless run_id

		tests = @db.execute(<<~SQL, [run_id, worker, sequence]).map { |row| OrderedTest.new(*row) }
			SELECT tests.path, tests.line, tests.class_name, tests.description
			FROM results JOIN tests ON tests.id = results.test_id
			WHERE results.run_id = ? AND results.worker = ? AND results.sequence <= ?
			ORDER BY results.sequence
		SQL

		FailureOrder.new(run_id:, seed:, slot:, before: tests[...-1], test: tests.last)
	rescue SQLite3::Exception => error
		raise Error, error.message
	end

	# Each test's results in the `quickdraw flaky` scan's runs after the run
	# with the id `after`, with the run's seed.
	def outcomes(scan:, after:)
		@db.execute(<<~SQL, [scan, after]).map { |row| Outcome.new(*row) }
			SELECT runs.id, tests.id, tests.path, tests.line, tests.class_name, tests.description, results.status, runs.seed
			FROM results JOIN tests ON tests.id = results.test_id JOIN runs ON runs.id = results.run_id
			WHERE runs.scan = ? AND runs.id > ?
			ORDER BY results.run_id
		SQL
	rescue SQLite3::Exception => error
		raise Error, error.message
	end

	# The tests with the longest average duration, longest first.
	def slowest_tests(limit:)
		@db.execute(<<~SQL, [limit]).map { |row| SlowTest.new(*row) }
			SELECT path, line, class_name, description, average_duration FROM tests
			WHERE average_duration IS NOT NULL
			ORDER BY average_duration DESC LIMIT ?
		SQL
	rescue SQLite3::Exception => error
		raise Error, error.message
	end

	# Tests that both passed and failed on the same code (see #git_revision)
	# within the last `within` runs, counting only the runs of code they did both on.
	def flaky_tests(within:)
		@db.execute(FLAKY_TESTS, [within]).map { |row| FlakyTest.new(*row) }
	rescue SQLite3::Exception => error
		raise Error, error.message
	end

	# `records` are History::Record; `load_errors` are [path, error] pairs;
	# `loaded_paths` are the files that loaded. `passed` is the run's outcome.
	def record_run(started_at:, finished_at:, seed:, processes:, worker_choice:, selection:, passed:, records:, loaded_paths:, load_errors:)
		sha, branch, code = @revision.value
		statuses = records.map { |record| status(record.result) }
		counts = statuses.tally
		durations = records.filter_map { |record| record.result["duration"] }

		@db.transaction do
			@db.execute(INSERT_RUN, [
				timestamp(started_at),
				timestamp(finished_at),
				seed,
				processes,
				sha,
				branch,
				code,
				ENV["QUICKDRAW_SCAN"],
				finished_at - started_at,
				records.size,
				counts.fetch("failed", 0),
				counts.fetch("errored", 0) + counts.fetch("crashed", 0) + load_errors.size,
				passed ? 1 : 0,
				selection,
				worker_choice,
				durations.sum,
				records.sum { |record| record.result["stats"]&.[](CPU) || 0 },
				durations.max || 0,
			])

			run_id = @db.last_insert_row_id
			ids = test_ids(records)

			insert_many(INSERT_RESULTS, records.zip(statuses).map { |record, status| result_row(run_id, ids.fetch(record.key), record, status) })
			@db.execute(UPDATE_STATS, { "smoothing" => SMOOTHING, "run_id" => run_id })

			insert_many(UPSERT_FILES, [
				*loaded_paths.map { |path| [path, nil, run_id] },
				*load_errors.map { |path, error| [path, JSON.generate(utf8(error)), run_id] },
			])

			prune(run_id)
		end

		# 0x10002 analyses every table, not just those this connection queried.
		@db.execute("PRAGMA optimize = 0x10002")
	rescue SQLite3::Exception => error
		raise Error, error.message
	end

	def close
		@db.close
	end

	private def connect(retried: false)
		@db = SQLite3::Database.new(@path)
		@db.busy_timeout = 5000
		PRAGMAS.each { |name, value| @db.execute("PRAGMA #{name} = #{value}") }

		# Immediate, so two runs can't both decide to rebuild.
		@db.transaction(:immediate) do
			version = @db.get_first_value("PRAGMA user_version")
			tables = @db.execute("SELECT name FROM sqlite_schema WHERE type = 'table'").flatten
			rebuild unless version == SCHEMA_VERSION && (TABLES - tables).empty?
		end

		@db.execute("PRAGMA wal_checkpoint(TRUNCATE)")

		# Read once, so recording a run only has to touch new or moved tests.
		@known = @db.execute("SELECT key, id, path, line, average_duration FROM tests").to_h do |key, id, path, line, average_duration|
			[key, KnownTest.new(id:, path:, line:, average_duration:)]
		end
	rescue SQLite3::CorruptException, SQLite3::NotADatabaseException
		raise if retried

		@db&.close
		Dir.glob("#{@path}*").each { |file| File.delete(file) }
		connect(retried: true)
	end

	private def rebuild
		@db.execute("SELECT name FROM sqlite_schema WHERE type = 'table'").flatten.each do |table|
			@db.execute("DROP TABLE #{table}")
		end

		@db.execute_batch(SCHEMA)
		@db.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
	end

	# Upserts new and moved tests, and returns { key => id }.
	private def test_ids(records)
		ids = {}
		changed = []

		records.each do |record|
			known = @known[record.key]

			if known && known.line == record.test["line"]
				ids[record.key] = known.id
			else
				changed << record
			end
		end

		changed.each_slice(BATCH_SIZE) do |batch|
			rows = batch.map { |record| [record.key, record.path, record.test["line"], record.test["class_name"], record.test["description"]] }

			@db.execute(format(UPSERT_TESTS, tuples(rows)), utf8(rows.flatten(1))).each do |id, key|
				ids[key] = id
			end
		end

		changed.each do |record|
			@known[record.key] = KnownTest.new(id: ids.fetch(record.key), path: record.path, line: record.test["line"], average_duration: @known[record.key]&.average_duration)
		end

		ids
	end

	private def result_row(run_id, test_id, record, status)
		result = record.result

		details = unless status == "passed"
			JSON.generate(utf8({ "failures" => result["failures"], "errors" => result["errors"] }))
		end

		[
			run_id,
			test_id,
			status,
			result["duration"],
			# The setup to allocations columns are in Quickdraw::STATS order.
			*(result["stats"] || Array.new(Quickdraw::STATS.size)),
			result["assertions"],
			record.worker,
			record.slot,
			record.sequence,
			details,
		]
	end

	private def insert_many(sql, rows)
		rows.each_slice(BATCH_SIZE) do |batch|
			@db.execute(format(sql, tuples(batch)), utf8(batch.flatten(1)))
		end
	end

	private def tuples(rows)
		tuple = "(#{(['?'] * rows.first.size).join(', ')})"
		([tuple] * rows.size).join(", ")
	end

	private def prune(run_id)
		oldest = run_id - KEPT_RUNS
		return if oldest < 1

		@db.execute("DELETE FROM results WHERE run_id <= ?", [oldest])
		@db.execute("DELETE FROM runs WHERE id <= ?", [oldest])
		@db.execute("DELETE FROM tests WHERE last_run_id <= ?", [oldest])
		@db.execute("DELETE FROM files WHERE last_run_id <= ?", [oldest])
	end

	private def status(result)
		if result["errors"].any? { |error| error["name"] == "Quickdraw::WorkerCrashed" }
			"crashed"
		else
			Quickdraw::Outcome.status(result)
		end
	end

	# Test descriptions and messages can be in any encoding, or invalid. SQLite and
	# JSON both need valid UTF-8, and keys must match what SQLite hands back.
	private def utf8(value)
		case value
		in String
			Quickdraw.utf8(value)
		in Array
			value.map { |item| utf8(item) }
		in Hash
			value.to_h { |key, item| [utf8(key), utf8(item)] }
		else
			value
		end
	end

	private def timestamp(time)
		time.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
	end

	# The commit, branch and code: the commit plus a hash of what's changed since,
	# from the moment the run started. Changes are tracked files' differences and
	# untracked Ruby files. Other untracked files are left out, since reports and
	# other output would make every run look like different code.
	private def git_revision
		output = IO.popen(["git", "rev-parse", "HEAD", "--abbrev-ref", "HEAD"], err: File::NULL, &:read)
		return [nil, nil, nil] unless $?.success?

		sha, branch = output.split("\n", 2).map(&:strip)
		diff = IO.popen(["git", "diff", "HEAD", "--binary", "--no-ext-diff", "--no-color"], err: File::NULL, &:read)
		untracked = IO.popen(["git", "ls-files", "--others", "--exclude-standard", "-z", "--", "*.rb"], err: File::NULL, &:read)
		return [sha, branch, sha] if diff.empty? && untracked.empty?

		digest = Digest::SHA256.new
		digest << diff

		untracked.split("\0").sort.each do |path|
			digest << "\0#{path}\0" << File.binread(path)
		rescue SystemCallError
			nil
		end

		code = "#{sha}+#{digest.hexdigest[0, 12]}"

		[sha, branch, code]
	rescue Errno::ENOENT
		[nil, nil, nil]
	end
end
