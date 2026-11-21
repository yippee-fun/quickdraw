# frozen_string_literal: true

class Quickdraw::Configuration
	# Test files matching any of `patterns` (globs relative to the project, such
	# as "test/browser/**/*.test.rb") run in processes of their own, booted with
	# `setup` as well as the rest of the config. Other tests never see what
	# `setup` loads. With a `gemfile`, they run with that bundle instead of the
	# one Quickdraw runs with.
	#
	# `cores` is how many CPU cores each of its workers uses, counting what it
	# runs beside it, such as a browser, so the group gets fewer workers.
	# `file_seconds` is how long one of its files is expected to take before
	# history says, so a group of slow tests gets workers early on.
	#
	# A group with a `variant` (such as a browser's name) is one of several
	# that each run every file matching them, rather than only the first
	# group's. Its tests' names, results and history say which.
	#
	# A `browser` group's tests, such as config.browser's, are left out of a
	# plain run unless named (see Coordinator#selected?). `qd browser` runs only them.
	Group = Data.define(:name, :patterns, :gemfile, :setup, :cores, :file_seconds, :browser, :variant) do
		def match?(path) = patterns.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
	end

	def initialize
		@before_forking_callbacks = []
		@after_forking_callbacks = []
		@around_test_callbacks = []
		@flaky_callbacks = []
		@groups = []
		@timeout = 300
		@settings = {}
	end

	attr_reader :before_forking_callbacks
	attr_reader :after_forking_callbacks
	attr_reader :flaky_callbacks
	attr_reader :groups

	# The run settings config set (see below), which the command line's
	# options override. Read in the loader, which reports them to the
	# coordinator, since that never loads config.
	attr_reader :settings

	# The most retries config can set, since the channels for them are opened
	# before config is read. `--retry N` can ask for more.
	MOST_RETRIES = 3

	# As --leaks: :warn, :fail or :off.
	def leaks=(mode)
		raise ArgumentError, "config.leaks must be :warn, :fail or :off, not #{mode.inspect}." unless mode in :warn | :fail | :off

		@settings[:leaks] = mode
	end

	# As --retry.
	def retries=(count)
		unless (Integer === count) && count.between?(0, MOST_RETRIES)
			raise ArgumentError, "config.retries must be 0 to #{MOST_RETRIES}, not #{count.inspect}. --retry N can retry more."
		end

		@settings[:retries] = count
	end

	# As --processes.
	def processes=(count)
		raise ArgumentError, "config.processes must be 1 or more, not #{count.inspect}." unless (Integer === count) && count >= 1

		@settings[:processes] = count
	end

	# As --flakes.
	def flakes=(path)
		raise ArgumentError, "config.flakes must be a path, not #{path.inspect}." unless String === path

		@settings[:flakes] = path
	end

	# As --allow-flaky, --quarantine, --no-capture (capture = false), --elastic
	# and --[no-]yjit.
	[:allow_flaky, :quarantine, :capture, :elastic, :yjit].each do |name|
		define_method(:"#{name}=") do |value|
			raise ArgumentError, "config.#{name} must be true or false, not #{value.inspect}." unless value in true | false

			@settings[name] = value
		end
	end

	# Leaves files matching any of `patterns` (globs relative to the project),
	# or under directories matching them, out of --coverage's reports:
	# `config.exclude_from_coverage("fixtures", "lib/generated/**/*.rb")`.
	def exclude_from_coverage(*patterns)
		unless patterns.any? && patterns.all?(String)
			raise ArgumentError, "exclude_from_coverage needs globs, such as \"fixtures\", not #{patterns.inspect}."
		end

		(@settings[:excluded_from_coverage] ||= []).concat(patterns.map { |pattern| pattern.delete_prefix("./").chomp("/") })
	end

	# Called with each test that failed, then passed when retried (a Flake),
	# once the run's tests have finished, in the process that booted config:
	# `config.on_flaky { |flake| Sentry.capture_message("Flaky: #{flake.name}", fingerprint: [flake.key]) }`.
	# Not in watch mode.
	def on_flaky(&block)
		raise ArgumentError, "on_flaky needs a block." unless block

		@flaky_callbacks << block
	end

	# Wraps every test, with its setup and teardown, in the block, which calls
	# `run` to run it: `config.around_test { |test, run| transaction { run.call } }`.
	# The first defined is outermost.
	def around_test(&block)
		@around_test_callbacks << block
	end

	# Runs the block inside the around_test callbacks, for `test`.
	def around(test)
		return yield if @around_test_callbacks.empty?

		ran = false
		run = -> { ran = true; yield }
		@around_test_callbacks.reverse.reduce(run) { |inner, callback| -> { callback.call(test, inner) } }.call
		raise "An around_test callback in config didn’t call run, so the test didn’t run." unless ran
	end

	# Boots the Rails app in config/environment.rb (or `environment`) for tests,
	# with a database for each worker and each test in a transaction. Every test
	# gets `fixtures` (:all, or a list of sets) from `fixture_paths`, as if
	# Quickdraw::BasicTest declared them. See Quickdraw::Rails.
	def rails(environment: "config/environment", fixtures: nil, fixture_paths: ["test/fixtures"])
		Quickdraw::Rails.setup(self, environment:, fixtures: fixtures && Array(fixtures), fixture_paths:)
	end

	# Runs the browser tests, the files matching `patterns`, in a group of their
	# own, or with `browsers: [:chromium, :firefox]`, in a group for each
	# browser, each running all of them. The block returns the Rack app they
	# test, such as Rails.application, which each worker serves. See
	# Quickdraw::Browser.prepare for the options. With `by_default: true`, a
	# plain run includes them, as `qd all` does.
	def browser(*patterns, gemfile: nil, by_default: false, **, &app)
		raise ArgumentError, "config.browser’s by_default must be true or false, not #{by_default.inspect}." unless by_default in true | false

		Quickdraw::Browser.configure(self, patterns, gemfile:, app:, **)
		@settings[:browser_by_default] = by_default
	end

	# Seconds before a test times out, or nil for never. A test can set its own
	# with `test("…", timeout: 5)`.
	attr_accessor :timeout

	# Runs once in the loader, after config and helpers load and before workers fork.
	def before_forking(&block)
		@before_forking_callbacks << block
	end

	# In watch mode, the loader stays booted between runs. When files it loaded
	# change, it boots again, unless this block, given their absolute paths,
	# reloads them and returns true. See Rails#reload.
	def reloader(&block)
		@reloader = block
	end

	# Whether the reloader reloaded `paths`.
	def reload(paths) = !!@reloader&.call(paths)

	# Runs in each worker after it forks. `QUICKDRAW_WORKER` holds the worker’s index.
	def after_forking(&block)
		@after_forking_callbacks << block
	end

	# Defines a group (see Group). A file in more than one group goes in the
	# first, or if that has a variant, in every group with a variant it's in.
	# The block runs after the before_forking callbacks.
	def group(name, *patterns, gemfile: nil, cores: 1, file_seconds: nil, browser: false, variant: nil, &setup)
		name = name.to_s
		variant = variant&.to_s
		raise ArgumentError, "The #{name} group’s browser must be true or false, not #{browser.inspect}." unless browser in true | false
		raise ArgumentError, "The #{name} group’s variant must be a word, such as firefox, not #{variant.inspect}." if variant && !variant.match?(/\A[\w.-]+\z/)
		raise ArgumentError, "There’s already a group with the #{variant} variant." if variant && @groups.any? { |group| group.variant == variant }
		# Without fork, every group's setup runs in one process, so variants can't run apart.
		raise ArgumentError, "The #{name} group can’t have a variant, since #{RUBY_ENGINE} can’t fork." if variant && !Process.respond_to?(:fork)
		raise ArgumentError, "The #{name} group needs a pattern for its files, such as \"test/#{name}/**/*.test.rb\"." if patterns.empty?
		raise ArgumentError, "The #{name} group’s cores must be a whole number of 1 or more, not #{cores.inspect}." unless (Integer === cores) && cores >= 1
		if file_seconds && !((Numeric === file_seconds) && file_seconds.positive?)
			raise ArgumentError, "The #{name} group’s file_seconds must be a positive number, not #{file_seconds.inspect}."
		end
		raise ArgumentError, "There’s already a group named #{name}." if @groups.any? { |group| group.name == name }
		if gemfile
			raise ArgumentError, "The #{name} group’s Gemfile, #{gemfile}, doesn’t exist." unless File.file?(gemfile)
			raise ArgumentError, "The #{name} group can’t have its own Gemfile, since #{RUBY_ENGINE} can’t fork." unless Process.respond_to?(:fork)
		end

		@groups << Group.new(name:, patterns: patterns.map(&:to_s).freeze, gemfile: gemfile && File.expand_path(gemfile), setup:, cores:, file_seconds:, browser:, variant:)
	end
end
