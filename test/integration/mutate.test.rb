# frozen_string_literal: true

require_relative "../support/integration"

require "json"

class MutateTest < Quickdraw::Test
	include Integration

	def setup
		super
		skip "mutate needs fork" unless Process.respond_to?(:fork)
	end

	PRICING = <<~RUBY
		# frozen_string_literal: true

		module Shop
			class Pricing
				def discount(total)
					if total > 100
						total / 10
					else
						0
					end
				end
			end
		end
	RUBY

	STRONG = <<~RUBY
		require_relative "../lib/pricing"

		class PricingTest < Quickdraw::Test
			test("discounts big orders") { assert_equal Shop::Pricing.new.discount(200), 20 }
			test("discounts from just over 100") { assert_equal Shop::Pricing.new.discount(101), 10 }
			test("doesn't discount 100") { assert_equal Shop::Pricing.new.discount(100), 0 }
		end
	RUBY

	WEAK = <<~RUBY
		require_relative "../lib/pricing"

		class PricingTest < Quickdraw::Test
			test("discounts big orders") { assert_equal Shop::Pricing.new.discount(200), 20 }
			test("doesn't discount small orders") { assert_equal Shop::Pricing.new.discount(5), 0 }
		end
	RUBY

	test "kills every mutant when the tests check the code", timeout: 30 do
		result = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => STRONG).run("mutate", "lib/pricing.rb", "--format", "agent")

		assert result.success?
		match { result => { stdout: /^MUTATION SCORE: 100% \(11 of 11 killed\)\. 11 mutants in [\d.]+s/ } }
		refute_includes result.stdout, "SURVIVED"
	end

	test "lists mutants no test notices a line each, with the change and the tests that ran it a command away", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => WEAK)
		result = project.run("mutate", "lib/pricing.rb", "--format", "agent")

		assert_equal result.exit_status, 1
		match { result => { stdout: %r{^SURVIVED (\h{12}) lib/pricing.rb:6 Shop::Pricing#discount: > → >= \(2 tests ran it\)$} } }
		id = $1
		assert_match result.stdout, %r{^SURVIVED \h{12} lib/pricing.rb:6 Shop::Pricing#discount: 100 → 101 \(2 tests ran it\)$}
		refute_includes result.stdout, "if total >= 100"
		match { result => { stdout: /^MUTATION SCORE: 63.6% \(7 of 11 killed, 4 survived\)/ } }
		assert_match result.stdout, /^Details: \S+ mutate --show \h{12} \(the change, and the tests that ran it\)\. All survivors: \S+ mutate --show all$/
		assert_equal File.read(File.join(project.directory, "lib/pricing.rb")), PRICING

		# The same id, since nothing changed.
		assert_includes project.run("mutate", "lib/pricing.rb", "--format", "agent").stdout, "SURVIVED #{id} lib/pricing.rb:6"

		shown = project.run("mutate", "--show", id)
		assert shown.success?
		assert_includes shown.stdout, "SURVIVED #{id} lib/pricing.rb:6 Shop::Pricing#discount: > → >=\n- if total > 100\n+ if total >= 100\nTests that ran it and passed:\n"
		# Fastest first.
		assert_equal shown.stdout.lines.grep(/^- test/).map(&:chomp).sort, ["- test/pricing.test.rb:4 PricingTest › discounts big orders", "- test/pricing.test.rb:5 PricingTest › doesn't discount small orders"]

		assert_equal project.run("mutate", "--show", "all").stdout.lines.grep(/^SURVIVED/).size, 4
		match { project.run("mutate", "--show", "nope") => { exit_status: 1, stderr: /no survivor nope/ } }
	end

	test "runs only the last run's survivors again with --survivors, counting its kills", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => WEAK)
		match { project.run("mutate", "lib/pricing.rb", "--format", "agent") => { stdout: /^MUTATION SCORE: 63.6% \(7 of 11 killed, 4 survived\)/ } }

		project.write("test/pricing.test.rb" => STRONG)
		result = project.run("mutate", "--survivors", "--format", "agent")

		assert result.success?
		assert_includes result.stdout, "MUTATION SCORE: 100% (11 of 11 killed). 4 mutants in "
		assert_includes result.stdout, ", and 7 killed in the last run, not run again\n"

		# Its kills count as the last run's, so running it again runs nothing.
		match { project.run("mutate", "--survivors", "--format", "agent") => { stdout: /MUTATION SCORE: 100% \(11 of 11 killed\). 0 mutants in .*, and 11 killed in the last run, not run again/ } }

		match { project.run("mutate", "--survivors", "lib/pricing.rb") => { exit_status: 2, stderr: /can’t be used with files/ } }
	end

	test "lists survivors that only empty an error's message apart, counting them the same", timeout: 30 do
		project = project(
			"lib/age.rb" => <<~RUBY,
				class Age
					def self.check(age)
						raise ArgumentError, "age can't be negative" if age.negative?
						age
					end
				end
			RUBY
			"test/age.test.rb" => <<~RUBY,
				require_relative "../lib/age"
				class AgeTest < Quickdraw::Test
					test("passes ages") { assert_equal Age.check(3), 3 }
					test("refuses negative ages") { assert_raises(ArgumentError) { Age.check(-1) } }
				end
			RUBY
		)

		agent = project.run("mutate", "lib/age.rb", "--format", "agent")
		refute_match agent.stdout, /^SURVIVED \h{12} .*age can't be negative/
		assert_match agent.stdout, %r{^SURVIVED MESSAGES: 1 mutant only empties an error’s message, which no test checks, such as \h{12} lib/age.rb:3 \(\S+ mutate --show all lists them\)$}
		assert_match agent.stdout, /^MUTATION SCORE: .*1 survived/

		human = project.run("mutate", "lib/age.rb", "--format", "human")
		assert_includes human.stdout, "SURVIVED 1 mutant emptying an error’s message"
		assert_match human.stdout, %r{^    lib/age.rb:3 Age.check  "age can't be negative" → "" · \h{12}$}

		report = JSON.parse(project.run("mutate", "lib/age.rb", "--format", "json").stdout)
		assert_equal report["survivors"].map { |survivor| survivor["message"] }, [true]
	end

	test "notices code the tests can do without, such as a call to strip", timeout: 30 do
		greeter = <<~'RUBY'
			module Greeter
				def self.greet(name) = "Hello, #{name.strip}!"
			end
		RUBY
		weak = <<~RUBY
			require_relative "../lib/greeter"

			class GreeterTest < Quickdraw::Test
				test("greets") { assert_equal Greeter.greet("Ada"), "Hello, Ada!" }
			end
		RUBY
		strong = weak.sub("\nend", "\n\ttest(\"trims\") { assert_equal Greeter.greet(\" Ada \"), \"Hello, Ada!\" }\nend")

		project = project("lib/greeter.rb" => greeter, "test/greeter.test.rb" => weak)
		result = project.run("mutate", "lib/greeter.rb", "--format", "agent")

		match { result => { stdout: %r{^SURVIVED (\h{12}) lib/greeter.rb:2 Greeter.greet: removed .strip \(1 test ran it\)$} } }
		assert_includes project.run("mutate", "--show", $1).stdout, "- def self.greet(name) = \"Hello, \#{name.strip}!\"\n+ def self.greet(name) = \"Hello, \#{name}!\"\nTests that ran it and passed:\n- test/greeter.test.rb:4 GreeterTest › greets\n"
		assert_includes result.stdout, "MUTATION SCORE: 66.7% (2 of 3 killed, 1 survived)"

		project.write("test/greeter.test.rb" => strong)
		result = project.run("mutate", "lib/greeter.rb", "--format", "agent")

		assert result.success?
		assert_includes result.stdout, "MUTATION SCORE: 100% (3 of 3 killed)"
	end

	test "passes when the score reaches --threshold", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => WEAK)

		assert project.run("mutate", "lib/pricing.rb", "--threshold", "63").success?
		assert_equal project.run("mutate", "lib/pricing.rb", "--threshold", "64").exit_status, 1
	end

	test "reports survivors for people, and as JSON", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => WEAK)
		human = project.run("mutate", "lib/pricing.rb", "--format", "human")

		assert_match human.stdout, %r{^SURVIVED > → >=  Shop::Pricing#discount · lib/pricing\.rb:6 · \h{12}\n\n    - if total > 100\n    \+ if total >= 100\n}
		match { human => { stdout: /^FAILED 63.6% mutation score · 7 killed · 4 survived$/ } }

		report = JSON.parse(project.run("mutate", "lib/pricing.rb", "--format", "json").stdout, symbolize_names: true)

		match do
			report => {
				score: 63.64,
				killed: 7,
				survived: 4,
				survivors: [{ id: /\A\h{12}\z/, path: "lib/pricing.rb", line: 6, method: "Shop::Pricing#discount", description: "condition → true", tests: [_, _] }, *],
			}
		end
	end

	test "mutates the lines changed since the last commit", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => WEAK, ".gitignore" => ".quickdraw/\n")
		project.commit
		project.write("lib/pricing.rb" => PRICING.sub("total / 10", "total / 20"), "test/pricing.test.rb" => WEAK.sub("), 20 }", "), 10 }"))

		result = project.run("mutate", "--format", "agent")

		assert result.success?
		match { result => { stdout: /^MUTATION SCORE: 100% \(4 of 4 killed\)/ } }
		assert_includes project.run("mutate", "lib/pricing.rb:9", "--format", "agent").stdout, "2 of 2 killed"
	end

	test "says when nothing changed", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => STRONG)
		project.commit

		result = project.run("mutate")

		assert result.success?
		assert_equal result.stdout, "Nothing to mutate in the lines changed since the last commit.\n"
	end

	test "still reports JSON when there's nothing to mutate", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => STRONG)
		project.commit

		result = project.run("mutate", "--format", "json")

		assert result.success?
		assert_includes result.stderr, "Nothing to mutate"
		match { result => { stdout: /\A\{"score":null,"threshold":100.0,"mutants":0,/ } }
	end

	test "fails when tests couldn't run, even though every mutant was killed", timeout: 30 do
		result = project(
			"lib/pricing.rb" => PRICING,
			"test/pricing.test.rb" => STRONG,
			"lib/broken.rb" => "module Broken\n\tdef self.one = 1\nend\n",
			"test/broken.test.rb" => "require_relative '../lib/broken'\nraise 'broken'\n",
			"lib/crash.rb" => "module Crash\n\tdef self.one = 1\nend\n",
			# Exits while a process it started holds the worker's pipe open.
			"test/crash.test.rb" => "require_relative '../lib/crash'\nclass CrashTest < Quickdraw::Test\n\ttest('crashes') { fork { sleep 30 }; Crash.one; exit!(1) }\nend\n",
		).run("mutate", "lib", "--format", "agent")

		match { result => { exit_status: 1, stdout: /MUTATION SCORE: 100%/, stderr: /failed to load, crashed or timed out/ } }
		assert_includes result.stderr, "test/broken.test.rb"
		assert_includes result.stderr, "test/crash.test.rb"
	end

	test "finds tests by name when the run history can't be read", timeout: 30 do
		result = project(
			"lib/pricing.rb" => PRICING,
			"test/pricing.test.rb" => STRONG,
			".quickdraw/history.sqlite3" => "not a database",
		).run("mutate", "lib/pricing.rb", "--format", "agent")

		assert result.success?
		assert_includes result.stderr, "Couldn’t read the run history"
	end

	test "finds the tests that run a file from the coverage map", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/checkout.test.rb" => STRONG)

		without_map = project.run("mutate", "lib/pricing.rb", "--format", "agent")
		assert_includes without_map.stderr, "No --coverage run has mapped which tests run which files"
		assert_includes without_map.stdout, "No tests run lib/pricing.rb"

		project.run("--coverage", "-p", "1")
		with_map = project.run("mutate", "lib/pricing.rb", "--format", "agent")

		assert with_map.success?
		assert_equal with_map.stderr, ""
		assert_includes with_map.stdout, "MUTATION SCORE: 100% (11 of 11 killed)"
	end

	test "skips mutants on lines no test runs, and tests that fail without mutations", timeout: 30 do
		result = project(
			"lib/pricing.rb" => PRICING,
			"test/pricing.test.rb" => <<~RUBY,
				require_relative "../lib/pricing"

				class PricingTest < Quickdraw::Test
					test("discounts big orders") { assert_equal Shop::Pricing.new.discount(200), 20 }
					test("is wrong") { assert_equal Shop::Pricing.new.discount(5), 1 }
				end
			RUBY
		).run("mutate", "lib/pricing.rb", "--format", "agent")

		assert_includes result.stderr, "1 test failed without mutations, so it doesn’t count: test/pricing.test.rb:5"
		assert_includes result.stdout, "NOT COVERED: 1 mutant on lines no test runs: lib/pricing.rb:9"
	end

	test "times out mutants that loop forever, which kills them", timeout: 30 do
		result = project(
			"lib/counter.rb" => <<~RUBY,
				class Counter
					def self.count_to(limit)
						count = 0
						count += 1 while count < limit
						count
					end
				end
			RUBY
			"test/counter.test.rb" => <<~RUBY,
				require_relative "../lib/counter"
				class CounterTest < Quickdraw::Test
					test("counts") { assert_equal Counter.count_to(3), 3 }
					test("counts to 0") { assert_equal Counter.count_to(0), 0 }
				end
			RUBY
		).run("mutate", "lib/counter.rb", "--format", "agent")

		# count += 0 never finishes.
		assert result.success?
		assert_includes result.stdout, "MUTATION SCORE: 100% (7 of 7 killed)"
	end

	test "times a mutant out by the test it hangs in, not by all its tests' time", timeout: 30 do
		result = project(
			"lib/waiter.rb" => <<~RUBY,
				class Waiter
					def self.wait
						sleep 0.2
						true
					end
				end
			RUBY
			"test/waiter.test.rb" => <<~RUBY,
				require_relative "../lib/waiter"
				class WaiterTest < Quickdraw::Test
					8.times do |index|
						test("waits \#{index}") { assert Waiter.wait }
					end
				end
			RUBY
		).run("mutate", "lib/waiter.rb", "--format", "json")

		report = JSON.parse(result.stdout)

		# Sleeping 1.2s overruns the first test's 1.1s, where all eight tests' would be 5.3s.
		assert_equal report["timed_out"], 1
		assert_operator report["duration"], :<, 5
	end

	test "keeps a mutated method's visibility, and module functions' copies", timeout: 30 do
		result = project(
			"lib/secrets.rb" => <<~RUBY,
				class Vault
					private def code = 42
				end

				module Helpers
					module_function

					def double(n) = n * 2
				end
			RUBY
			"test/secrets.test.rb" => <<~RUBY,
				require_relative "../lib/secrets"
				class SecretsTest < Quickdraw::Test
					test("hides the code") do
						Vault.new.send(:code)
						assert_raises(NoMethodError) { Vault.new.code }
					end

					test("doubles") { assert_equal Helpers.double(3), 6 }
				end
			RUBY
		).run("mutate", "lib/secrets.rb", "--format", "agent")

		# Only a still-private method raises, so every mutant of it survives.
		assert_equal result.stdout.scan(%r{^SURVIVED \h{12} lib/secrets.rb:2 Vault#code}).size, 3
		refute_includes result.stdout, "Helpers"
		assert_includes result.stdout, "(4 of 7 killed, 3 survived)"
	end

	test "applies mutants within the classes and modules around them, so constants resolve", timeout: 30 do
		result = project(
			"lib/shop.rb" => <<~RUBY,
				module Shop
					RATE = 2

					class Tax
						class << self
							def on(amount) = amount * RATE
						end
					end

					module Billing; end

					class Invoice
						class Billing::Total
							def self.of(amount) = amount + 1
						end
					end
				end
			RUBY
			"test/shop.test.rb" => <<~RUBY,
				require_relative "../lib/shop"
				class ShopTest < Quickdraw::Test
					test("taxes") { assert_equal Shop::Tax.on(3), 6 }
					test("totals") { assert_equal Shop::Billing::Total.of(3), 4 }
				end
			RUBY
		).run("mutate", "lib/shop.rb", "--format", "agent")

		assert result.success?
		assert_includes result.stdout, "MUTATION SCORE: 100% (6 of 6 killed)"
	end

	test "finds a class named within one around it through that class's ancestors", timeout: 30 do
		result = project(
			"lib/shapes.rb" => <<~RUBY,
				class Base
					module Inner; end
				end

				class Derived < Base
					class Inner::Child
						def self.double(n) = n * 2
					end
				end
			RUBY
			"test/shapes.test.rb" => <<~RUBY,
				require_relative "../lib/shapes"
				class ShapesTest < Quickdraw::Test
					test("doubles") { assert_equal Base::Inner::Child.double(3), 6 }
				end
			RUBY
		).run("mutate", "lib/shapes.rb", "--format", "agent")

		assert result.success?
		assert_includes result.stdout, "MUTATION SCORE: 100% (4 of 4 killed)"
	end

	test "mutates methods in Data.define, Struct.new and class_methods blocks, within the constant scope around them", timeout: 30 do
		project = project(
			"lib/concern.rb" => <<~RUBY,
				module Concern
					def class_methods(&) = const_set(:ClassMethods, Module.new(&))
					def included(base) = base.extend(const_get(:ClassMethods))
				end
			RUBY
			"lib/geometry.rb" => <<~RUBY,
				require_relative "concern"

				module Geometry
					SCALE = 2

					Point = Data.define(:x, :y) do
						def scaled = x * SCALE
					end

					module Units
						extend Concern

						class_methods do
							def unit = "cm"
						end
					end
				end

				Geometry::Pair = Struct.new(:a, :b, keyword_init: true) do
					def sum = a + b
				end
			RUBY
			"test/geometry.test.rb" => <<~RUBY,
				require_relative "../lib/geometry"
				class GeometryTest < Quickdraw::Test
					test("scales") { assert_equal Geometry::Point.new(x: 3, y: 0).scaled, 6 }
					test("sums") { assert_equal Geometry::Pair.new(a: 3, b: 1).sum, 4 }
					test("has units") { assert_equal Class.new { include Geometry::Units }.unit, "cm" }
				end
			RUBY
		)

		result = project.run("mutate", "lib/geometry.rb", "--format", "agent")

		assert result.success?
		assert_includes result.stdout, "MUTATION SCORE: 100% (6 of 6 killed)"

		project.write("test/geometry.test.rb" => <<~RUBY)
			require_relative "../lib/geometry"
			class GeometryTest < Quickdraw::Test
				test("scales") { assert_equal Geometry::Point.new(x: 0, y: 0).scaled, 0 }
				test("sums") { assert_equal Geometry::Pair.new(a: 1, b: 0).sum, 1 }
				test("has units") { assert Class.new { include Geometry::Units }.unit }
			end
		RUBY

		result = project.run("mutate", "lib/geometry.rb", "--format", "agent")

		assert_match result.stdout, %r{^SURVIVED \h{12} lib/geometry.rb:7 Geometry::Point#scaled: \* → / \(1 test ran it\)$}
		assert_match result.stdout, %r{^SURVIVED \h{12} lib/geometry.rb:20 Geometry::Pair#sum: \+ → - \(1 test ran it\)$}
		assert_match result.stdout, %r{^SURVIVED \h{12} lib/geometry.rb:14 Geometry::Units::ClassMethods#unit: "cm" → "" \(1 test ran it\)$}
		assert_includes result.stdout, "MUTATION SCORE: 50% (3 of 6 killed, 3 survived)"
	end

	test "mutates methods in files with another encoding", timeout: 30 do
		result = project(
			"lib/menu.rb" => "# encoding: iso-8859-1\n# frozen_string_literal: true\nmodule Menu\n\tdef self.item(hot) = hot ? \"caf\xE9\" : \"th\xE9\"\n\tdef self.acute?(word) = word.match?(/\\xE9/)\nend\n",
			"test/menu.test.rb" => <<~RUBY,
				require_relative "../lib/menu"
				class MenuTest < Quickdraw::Test
					test("hot") { assert_equal Menu.item(true).encode("UTF-8"), "café" }
					test("cold") { assert_equal Menu.item(false).encode("UTF-8"), "thé" }
					test("acute") { assert Menu.acute?(Menu.item(true)) }
				test("plain") { refute Menu.acute?("tea") }
				test("diaeresis") { refute Menu.acute?("na\\xEFve".dup.force_encoding("ISO-8859-1")) }
				end
			RUBY
		).run("mutate", "lib/menu.rb", "--format", "agent")

		assert result.success?
		assert_includes result.stdout, "MUTATION SCORE: 100% (8 of 8 killed)"
	end

	test "fails, in every format, when a method is replaced before its tests run", timeout: 30 do
		project = project(
			"lib/pricing.rb" => PRICING,
			"test/pricing.test.rb" => "#{STRONG}\nShop::Pricing.class_eval { def discount(total) = (total > 100) ? total / 10 : 0 }\n",
		)

		agent = project.run("mutate", "lib/pricing.rb", "--format", "agent")
		match { agent => { exit_status: 1, stdout: %r{^Couldn’t find Shop::Pricing#discount \(lib/pricing.rb:5\) once tests had loaded, so 11 mutants didn’t run\.$} } }

		json = project.run("mutate", "lib/pricing.rb", "--format", "json")
		assert_equal json.exit_status, 1
		match { JSON.parse(json.stdout, symbolize_names: true) => { missing: 11, missing_methods: [{ path: "lib/pricing.rb", line: 5, method: "Shop::Pricing#discount" }] } }
	end

	test "fails when a test file that ran a mutant unmutated doesn't load in the worker running it", timeout: 30 do
		result = project(
			"lib/pricing.rb" => PRICING,
			# Loads in the first worker only.
			"test/pricing.test.rb" => "File.open(File.join(__dir__, 'loaded'), File::CREAT | File::EXCL) {}\n#{STRONG}",
		).run("mutate", "lib/pricing.rb", "-p", "2", "--format", "agent")

		assert_equal result.exit_status, 1
		assert_includes result.stdout, "test/pricing.test.rb loaded in one worker but failed to load in another."
		refute_includes result.stdout, "SURVIVED"
	end

	test "times out tests that keep their watchdog from running before mutating", timeout: 30 do
		result = project(
			"lib/pricing.rb" => PRICING,
			"test/pricing.test.rb" => <<~RUBY,
				require_relative "../lib/pricing"
				class PricingTest < Quickdraw::Test
					# As a test stuck in native code that holds the GVL does.
					test("hangs", timeout: 0.1) do
						Thread.list.each { |thread| thread.kill unless thread == Thread.current }
						Shop::Pricing.new.discount(5)
						sleep
					end
				end
			RUBY
		).run("mutate", "lib/pricing.rb", "--format", "agent", timeout: 20)

		match { result => { exit_status: 1, stderr: %r{test/pricing.test.rb failed to load, crashed or timed out} } }
	end

	test "runs mutants when config ignores SIGCHLD", timeout: 30 do
		result = project(
			"config/quickdraw.rb" => "Quickdraw.configure { |config| config.after_forking { trap(:CHLD, 'IGNORE') } }\n",
			"lib/pricing.rb" => PRICING,
			"test/pricing.test.rb" => STRONG,
		).run("mutate", "lib/pricing.rb", "--format", "agent")

		assert result.success?
		assert_includes result.stdout, "MUTATION SCORE: 100% (11 of 11 killed)"
	end

	test "stops on Ctrl-C and reports what finished", timeout: 30 do
		project = project(
			"lib/pricing.rb" => PRICING,
			"test/pricing.test.rb" => STRONG.sub("class PricingTest < Quickdraw::Test", "class PricingTest < Quickdraw::Test\n\tdef setup = sleep(0.2)"),
		)

		result = project.run("mutate", "lib/pricing.rb", "-p", "1", "--format", "human", tty: [24, 120], interrupt_when: /Mutants: 1 of/)

		assert_equal result.exit_status, 130
		assert_includes result.stdout, "Interrupted after"
		assert_equal File.read(File.join(project.directory, "lib/pricing.rb")), PRICING
	end

	test "explains bad arguments", timeout: 20 do
		match { project.run("mutate", "--threshold", "lots") => { stderr: /--threshold needs a percentage/, exit_status: 2 } }
		match { project.run("mutate", "missing.rb") => { stderr: /missing.rb doesn’t exist/, exit_status: 2 } }
		match { project.run("mutate", "--frobnicate") => { stderr: /Unknown option --frobnicate/, exit_status: 2 } }
		match { project.run("mutate", "") => { stderr: /\A doesn’t exist/, exit_status: 2 } }
	end

	test "reports mutants left when every worker exited as unfinished", timeout: 30 do
		project = project(
			"lib/pricing.rb" => PRICING,
			"test/pricing.test.rb" => <<~RUBY,
				require_relative "../lib/pricing"

				class PricingTest < Quickdraw::Test
					test("kills its worker when mutated") do
						Process.kill(:KILL, Process.ppid) unless Shop::Pricing.new.discount(200) == 20
						assert true
					end
				end
			RUBY
		)

		result = project.run("mutate", "lib/pricing.rb", "--processes", "1", "--format", "agent")

		refute result.success?
		assert_includes result.stdout, "10 mutants didn’t finish, since the worker running them exited."
	end

	test "counts test files left when the worker loading them exited as broken", timeout: 30 do
		project = project(
			"lib/pricing.rb" => PRICING,
			"test/pricing.test.rb" => STRONG,
			"test/dies.test.rb" => STRONG.sub("class PricingTest", "Process.kill(:KILL, Process.pid) if File.exist?(\"die\")\n\nclass DiesTest"),
		)
		assert project.run("--coverage").success?
		project.write("die" => "")

		result = project.run("mutate", "lib/pricing.rb", "--processes", "1", "--format", "agent")

		refute result.success?
		assert_match result.stderr, %r{test/dies\.test\.rb.* failed to load, crashed or timed out}
	end

	test "mutates the whole project given ./", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => STRONG)

		match { project.run("mutate", "./", "--format", "agent") => { stdout: /^MUTATION SCORE: 100% \(11 of 11 killed\)/ } }
		match { project.run("mutate", "#{File.realpath(project.directory)}/", "--format", "agent") => { stdout: /^MUTATION SCORE: 100% \(11 of 11 killed\)/ } }
	end

	MATRIX = <<~RUBY
		require_relative "../lib/pricing"

		class PricingTest < Quickdraw::Test
			test("discounts big orders") { assert_equal Shop::Pricing.new.discount(200), 20 }
			test("discounts other big orders") { assert_equal Shop::Pricing.new.discount(300), 30 }
			test("doesn't discount 100") { assert_equal Shop::Pricing.new.discount(100), 0 }
			test("discounts from just over 100") { assert_equal Shop::Pricing.new.discount(101), 10 }
			test("runs small orders") { Shop::Pricing.new.discount(5); assert true }
		end
	RUBY

	test "--matrix lists tests that kill no mutants and tests whose kills others make too, with the same score", timeout: 40 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => MATRIX)
		plain = project.run("mutate", "lib/pricing.rb", "--format", "agent")
		matrix = project.run("mutate", "lib/pricing.rb", "--format", "agent", "--matrix")

		assert matrix.success?
		assert_equal matrix.stdout[/^MUTATION SCORE: [^.]*/], plain.stdout[/^MUTATION SCORE: [^.]*/]
		assert_includes matrix.stdout, "BLIND: test/pricing.test.rb:8 PricingTest › runs small orders ran against"
		assert_includes matrix.stdout, "REDUNDANT: test/pricing.test.rb:4 PricingTest › discounts big orders."
		assert_includes matrix.stdout, "REDUNDANT: test/pricing.test.rb:5 PricingTest › discounts other big orders."
		refute_includes matrix.stdout, "REDUNDANT: test/pricing.test.rb:6"
		refute_includes plain.stdout, "BLIND"

		human = project.run("mutate", "lib/pricing.rb", "--format", "human", "--matrix")
		assert_match human.stdout, %r{^Blind tests ran against mutants and killed none\n  test/pricing\.test\.rb:8 PricingTest › runs small orders  ran against \d+ mutants$}

		report = JSON.parse(project.run("mutate", "lib/pricing.rb", "--format", "json", "--matrix").stdout)
		assert_equal report["matrix"]["blind"].map { |test| test["line"] }, [8]
		assert_equal report["matrix"]["redundant"].map { |test| test["line"] }, [4, 5]
		assert_equal report["matrix"]["incomplete"], 0
		refute JSON.parse(project.run("mutate", "lib/pricing.rb", "--format", "json").stdout).key?("matrix")
	end

	test "--matrix keeps a kill when a later test crashes the mutant's fork, and doesn't judge its tests", timeout: 40 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => <<~RUBY)
			require_relative "../lib/pricing"

			class PricingTest < Quickdraw::Test
				test("discounts big orders") { assert_equal Shop::Pricing.new.discount(200), 20 }
				test("exits when a discount changes") { exit!(1) unless Shop::Pricing.new.discount(300) == 30; assert true }
				test("doesn't discount 100") { assert_equal Shop::Pricing.new.discount(100), 0 }
				test("discounts from just over 100") { assert_equal Shop::Pricing.new.discount(101), 10 }
			end
		RUBY

		plain = project.run("mutate", "lib/pricing.rb", "--format", "agent")
		matrix = project.run("mutate", "lib/pricing.rb", "--matrix", "--format", "json")

		report = JSON.parse(matrix.stdout)
		assert_equal "#{report['killed']} of #{report['killed'] + report['survived']}", plain.stdout[/MUTATION SCORE: \S+ \((\d+ of \d+)/, 1]
		assert_operator report["matrix"]["incomplete"], :>, 0
	end

	test "a run with nothing to mutate clears the last run's survivors", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "lib/constants.rb" => "LIMIT = 100\n", "test/pricing.test.rb" => WEAK)
		project.run("mutate", "lib/pricing.rb", "--format", "agent")
		assert_equal project.run("mutate", "--show", "all").stdout.lines.size, 4

		project.run("mutate", "lib/constants.rb", "--format", "agent")
		assert_equal project.run("mutate", "--show", "all").stdout, ""
	end

	test "--base mutates what changed since the branch left REF, committed or not, and not what REF gained since", timeout: 40 do
		project = project("lib/pricing.rb" => PRICING, "lib/other.rb" => "module Other\n\tdef self.double(n) = n * 2\nend\n", "test/pricing.test.rb" => STRONG, ".gitignore" => ".quickdraw/\n")
		project.commit
		project.git("switch", "--quiet", "-c", "feature")
		project.write("lib/pricing.rb" => PRICING.sub("\tend\nend\n", "\n\t\tdef tax(total) = total / 5\n\tend\nend\n"), "test/pricing.test.rb" => STRONG.sub("\nend\n", "\n\ttest(\"taxes\") { assert_equal Shop::Pricing.new.tax(50), 10 }\nend\n"))
		project.commit
		project.git("switch", "--quiet", "main")
		project.write("lib/other.rb" => "module Other\n\tdef self.double(n) = n * 3\nend\n")
		project.commit
		project.git("switch", "--quiet", "feature")

		assert_includes project.run("mutate", "--format", "agent").stdout, "Nothing to mutate in the lines changed since the last commit."

		mutants = -> (*arguments, **options) { JSON.parse(project.run("mutate", *arguments, "--format", "json", **options).stdout, symbolize_names: true)[:mutants] }
		committed = mutants.("--base", "main")
		assert_operator committed, :>, 0
		assert_operator mutants.("lib/pricing.rb"), :>, committed

		project.write("lib/other.rb" => "module Other\n\tdef self.double(n) = n * 4\nend\n")
		assert_operator mutants.("--base", "main"), :>, committed

		project.git("update-ref", "refs/remotes/origin/main", "main")
		assert_equal mutants.(env: { "GITHUB_BASE_REF" => "main" }), mutants.("--base", "main")
		assert_includes project.run("mutate", "--format", "agent", env: { "GITHUB_BASE_REF" => "nope" }).stderr, "Git can’t find"
	end

	test "--base explains when it can't be used", timeout: 20 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => STRONG, ".gitignore" => ".quickdraw/\n")
		project.commit

		match { project.run("mutate", "--base", "nope") => { stderr: /\AGit can’t find/, exit_status: 2 } }
		match { project.run("mutate", "--base", "HEAD", "lib/pricing.rb") => { stderr: /--base mutates the lines changed since a ref, so it can’t be used with files/, exit_status: 2 } }
		match { project.run("mutate", "--base") => { stderr: /--base needs a git ref/, exit_status: 2 } }
	end

	test "a mutant marked equivalent is left out and counted, with its reason, and the others keep their ids", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => WEAK)
		before = project.run("mutate", "lib/pricing.rb", "--format", "agent")
		ids = before.stdout.scan(%r{^SURVIVED (\h{12}) lib/pricing.rb:6 Shop::Pricing#discount: (.+?) \(}).to_h { |id, description| [description, id] }
		assert_includes ids, "> → >="

		marked = PRICING.sub("if total > 100", "if total > 100 # quickdraw:equivalent > → >= -- the discount at 100 is 10 either way")
		project.write("lib/pricing.rb" => marked)
		result = project.run("mutate", "lib/pricing.rb", "--format", "agent")

		refute_includes result.stdout, "> → >="
		assert_equal result.stdout.scan(%r{^SURVIVED (\h{12}) lib/pricing.rb:6 Shop::Pricing#discount: (.+?) \(}).to_h { |id, description| [description, id] }, ids.except("> → >=")
		assert_includes result.stdout, "MUTATION SCORE: 70% (7 of 10 killed, 3 survived, 1 marked equivalent)"
		refute_includes result.stderr, "marks"

		human = project.run("mutate", "lib/pricing.rb", "--format", "human")
		assert_includes human.stdout, "1 marked equivalent"

		report = JSON.parse(project.run("mutate", "lib/pricing.rb", "--format", "json").stdout, symbolize_names: true)
		match { report => { ignored: [{ id: /\A\h{12}\z/, path: "lib/pricing.rb", line: 6, method: "Shop::Pricing#discount", description: "> → >=", reason: "the discount at 100 is 10 either way" }] } }
	end

	test "a mark matches a mutant whose description has -- in it, as copied from the output", timeout: 30 do
		project = project(
			"lib/label.rb" => "module Label\n\tdef self.call = \"a -- b\" # quickdraw:equivalent \"a -- b\" → \"\" -- only shown\nend\n",
			"test/label.test.rb" => "require_relative \"../lib/label\"\nclass LabelTest < Quickdraw::Test\n\ttest(\"labels\") { assert Label.call }\nend\n",
		)

		result = project.run("mutate", "lib/label.rb", "--format", "json")

		refute_includes result.stderr, "marks"
		match { JSON.parse(result.stdout, symbolize_names: true) => { ignored: [{ description: "\"a -- b\" → \"\"", reason: "only shown" }] } }
	end

	test "warns about equivalence marks without a reason, or that match no mutant", timeout: 30 do
		marked = PRICING.sub("if total > 100", "if total > 100 # quickdraw:equivalent > → >=").sub("total / 10", "total / 10 # quickdraw:equivalent nonsense -- nothing to see")
		project = project("lib/pricing.rb" => marked, "test/pricing.test.rb" => WEAK)

		result = project.run("mutate", "lib/pricing.rb", "--format", "agent")

		assert_includes result.stderr, "lib/pricing.rb:6 marks a mutant equivalent without saying why. Add a reason after --."
		assert_includes result.stderr, "lib/pricing.rb:7 marks “nonsense” equivalent, but no mutant there matches."
		assert_includes result.stdout, "1 marked equivalent"

		report = JSON.parse(project.run("mutate", "lib/pricing.rb", "--format", "json").stdout, symbolize_names: true)
		match { report => { ignored: [{ reason: "no reason given" }] } }
	end

	UNIQUE_BASE = <<~RUBY
		require_relative "../lib/pricing"

		class PricingTest < Quickdraw::Test
			test("discounts big orders") { assert_equal Shop::Pricing.new.discount(200), 20 }
			test("doesn't discount 100") { assert_equal Shop::Pricing.new.discount(100), 0 }
			test("discounts from just over 100") { assert_equal Shop::Pricing.new.discount(101), 10 }
		end
	RUBY

	UNIQUE_FEATURE = <<~RUBY
		#{UNIQUE_BASE}
		class MorePricingTest < Quickdraw::Test
			test("discounts other big orders") { assert_equal Shop::Pricing.new.discount(300), 30 }
			test("taxes") { assert_equal Shop::Pricing.new.tax(50), 10 }
			test("renders", mutation: false) { assert true }
		end
	RUBY

	def unique_kills_project
		project = project("lib/pricing.rb" => PRICING.sub("\tend\nend\n", "\n\t\tdef tax(total) = total / 5\n\tend\nend\n"), "test/pricing.test.rb" => UNIQUE_BASE, ".gitignore" => ".quickdraw/\n")
		project.branch({ "test/pricing.test.rb" => UNIQUE_FEATURE })
		project
	end

	test "--unique-kills fails the tests a diff adds that kill no mutant another test doesn't", timeout: 60 do
		project = unique_kills_project

		result = project.run("mutate", "--base", "main", "--unique-kills", "--format", "agent")

		assert_equal result.exit_status, 1
		assert_equal result.stdout.scan(/^NOT UNIQUE: .*/).size, 1
		match { result => { stdout: %r{^NOT UNIQUE: test/pricing\.test\.rb:10 MorePricingTest › discounts other big orders kills no mutant another test doesn't\. } } }
		refute_includes result.stdout, "BLIND"
		refute_includes result.stdout, "REDUNDANT"
		refute_includes result.stdout, "UNIQUE KILLS:"
		match { result => { stdout: /^NO MUTANTS ON CHANGED LINES\. \d+ mutants to judge the tests this changes in / } }

		report = JSON.parse(project.run("mutate", "--base", "main", "--unique-kills", "--format", "json").stdout, symbolize_names: true)
		match { report => { mutants: 0, killed: 0, survived: 0, unique_kills: { tests: [*], not_unique: [{ name: "MorePricingTest › discounts other big orders" }] } } }
		assert_equal report[:unique_kills][:tests].to_h { |test| [test[:name], test[:exempt]] }, { "MorePricingTest › discounts other big orders" => false, "MorePricingTest › taxes" => false, "MorePricingTest › renders" => true }

		human = project.run("mutate", "--base", "main", "--unique-kills", "--format", "human")
		assert_includes human.stdout, "Tests that kill no mutant of their own"
		refute_includes human.stdout, "Blind tests"
		assert_includes project.run("mutate", "--base", "main", "--unique-kills", "--matrix", "--format", "agent").stdout, "REDUNDANT: test/pricing.test.rb:10"
	end

	test "--unique-kills passes when every test the diff changes kills a mutant of its own", timeout: 60 do
		project = unique_kills_project
		project.write("test/pricing.test.rb" => UNIQUE_FEATURE.sub("discount(300), 30", "discount(150), 15").sub("\ttest(\"discounts other big orders\") { assert_equal Shop::Pricing.new.discount(150), 15 }\n", ""))
		project.commit

		result = project.run("mutate", "--base", "main", "--unique-kills", "--format", "agent")

		assert result.success?
		assert_includes result.stdout, "UNIQUE KILLS: The test this changes kills a mutant no other test does."
	end

	test "--unique-kills judges a test changed only by deleting a line from it, and not its neighbours", timeout: 60 do
		before = <<~RUBY
			require_relative "../lib/pricing"

			class PricingTest < Quickdraw::Test
				test("discounts big orders") do
					assert_equal Shop::Pricing.new.discount(200), 20
					assert_equal Shop::Pricing.new.discount(101), 10
				end

				test("doesn't discount 100") { assert_equal Shop::Pricing.new.discount(100), 0 }
			end
		RUBY

		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => before, ".gitignore" => ".quickdraw/\n")
		project.branch({ "test/pricing.test.rb" => before.sub(/^.*discount\(101\).*\n/, "") })
		report = JSON.parse(project.run("mutate", "--base", "main", "--unique-kills", "--format", "json").stdout, symbolize_names: true)

		assert_equal report[:unique_kills][:tests].map { |test| test[:name] }, ["PricingTest › discounts big orders"]
	end

	test "--unique-kills fails a test the diff adds that runs nothing it can mutate", timeout: 60 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => STRONG, ".gitignore" => ".quickdraw/\n")
		project.branch({ "test/greeting.test.rb" => "class GreetingTest < Quickdraw::Test\n\ttest(\"greets\") { assert_equal \"hi\", \"hi\" }\nend\n" })
		result = project.run("mutate", "--base", "main", "--unique-kills", "--format", "agent")

		assert_equal result.exit_status, 1
		assert_match result.stdout, %r{^NOT UNIQUE: test/greeting\.test\.rb:2 GreetingTest › greets }
	end

	test "--unique-kills judges a test file the coverage map hasn't seen by its counterpart", timeout: 60 do
		files = { "lib/pricing.rb" => PRICING, "test/smoke.test.rb" => "require_relative \"../lib/pricing\"\n\nclass SmokeTest < Quickdraw::Test\n\ttest(\"runs\") { assert Shop::Pricing.new.discount(5) }\nend\n" }
		project = project(**files, ".gitignore" => ".quickdraw/\n")
		assert project.run("--coverage").success?
		project.branch({ "test/pricing.test.rb" => STRONG })

		result = project.run("mutate", "--base", "main", "--unique-kills", "--format", "agent")

		match { result => { stdout: /^NO MUTANTS ON CHANGED LINES\. \d+ mutants to judge the tests this changes in / } }
	end

	test "on GitHub Actions, annotates each survivor's line, but not in JSON", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => WEAK)
		result = project.run("mutate", "lib/pricing.rb", "--format", "agent", env: { "GITHUB_ACTIONS" => "true" })

		annotations = result.stdout.lines.grep(/\A::error /)
		assert_equal annotations.size, 4
		assert_match annotations.join, %r{^::error file=lib/pricing\.rb,line=6,title=Mutant survived%3A > → >=::No test noticed this change \(\h{12}\):%0A  - if total > 100%0A  \+ if total >= 100%0A}

		json = project.run("mutate", "lib/pricing.rb", "--format", "json", env: { "GITHUB_ACTIONS" => "true" })
		refute_includes json.stdout, "::error"
	end

	test "reuses mutants' outcomes until their code, their tests or what their tests run changes", timeout: 60 do
		project = project("lib/pricing.rb" => PRICING, "lib/other.rb" => "module Other\n\tdef self.double(n) = n * 2\nend\n", "test/pricing.test.rb" => WEAK)
		mutate = -> (*arguments) { project.run("mutate", "lib/pricing.rb", "--format", "agent", *arguments).stdout[/^MUTATION SCORE: .*/] }
		# So it's known that the tests don't run lib/other.rb. Without a map, any source changing counts.
		assert project.run("--coverage").success?

		first = mutate.()
		assert_match first, /\(7 of 11 killed, 4 survived\)\. 11 mutants in /

		# The same score and survivors, without running a mutant.
		assert_match mutate.(), /\(7 of 11 killed, 4 survived\)\. All 11 mutants unchanged since an earlier run, so none ran, in /
		assert_match mutate.("--no-cache"), %r{\. 11 mutants in [\d.]+s \(\d+/s\)\z}

		# A file the tests don't run changing doesn't matter, but the tests changing does.
		project.write("lib/other.rb" => "module Other\n\tdef self.double(n) = n + n\nend\n")
		assert_match mutate.(), /All 11 mutants unchanged/
		project.write("test/pricing.test.rb" => STRONG)
		assert_match mutate.(), /\(11 of 11 killed\)\. 11 mutants in /

		# The matrix needs every test's outcome, which a run that stopped at the first kill doesn't have.
		assert_match project.run("mutate", "lib/pricing.rb", "--format", "agent", "--matrix").stdout, /\. 11 mutants in /
		assert_match project.run("mutate", "lib/pricing.rb", "--format", "agent", "--matrix").stdout, /All 11 mutants unchanged/

		report = JSON.parse(project.run("mutate", "lib/pricing.rb", "--format", "json").stdout, symbolize_names: true)
		match { report => { cached: 11, killed: 11 } }
	end

	test "reuses outcomes when a source beside colocated tests that they don't run changes", timeout: 60 do
		project = project(
			"lib/pricing.rb" => PRICING,
			"lib/other.rb" => "module Other\n\tdef self.double(n) = n * 2\nend\n",
			"lib/pricing.test.rb" => WEAK.sub("../lib/pricing", "pricing"),
		)
		mutate = -> { project.run("mutate", "lib/pricing.rb", "--format", "agent").stdout[/^MUTATION SCORE: .*/] }
		assert project.run("--coverage").success?

		assert_match mutate.(), /\(7 of 11 killed, 4 survived\)\. 11 mutants in /
		project.write("lib/other.rb" => "module Other\n\tdef self.double(n) = n + n\nend\n")
		assert_match mutate.(), /All 11 mutants unchanged/
	end

	test "applies mutants with the refinements their file activates", timeout: 30 do
		result = project(
			"lib/greeting.rb" => <<~RUBY,
				module Shout
					refine(String) { def shout = "\#{upcase}!" }
				end

				module Quiet
					refine(String) { def quiet = downcase }
				end

				using Shout

				class Greeting
					using Quiet

					def call(name)
						"\#{name.shout} \#{name.quiet}" if name
					end
				end
			RUBY
			"test/greeting.test.rb" => <<~RUBY,
				require_relative "../lib/greeting"

				class GreetingTest < Quickdraw::Test
					test("greets, without refining code evaluated elsewhere") do
					assert_equal Greeting.new.call("Hi"), "HI! hi"
					assert_nil TOPLEVEL_BINDING.eval("'x'.shout rescue nil")
				end
				end
			RUBY
		).run("mutate", "lib/greeting.rb", "--format", "agent")

		match { result => { stdout: %r{^SURVIVED \S+ lib/greeting\.rb:15 Greeting#call: condition → true } } }
	end

	test "says --unique-kills runs every test against each mutant, as --matrix does", timeout: 20 do
		help = project.run("mutate", "--help").stdout

		assert_includes help.gsub(/\s+/, " "), "Runs every test against each mutant, as --matrix does"
		refute_includes help, "Implies --matrix"
	end

	test "--unique-kills reports the mutants it couldn't run to judge the tests a diff changes", timeout: 60 do
		project = unique_kills_project
		project.write("test/pricing.test.rb" => <<~RUBY)
			#{UNIQUE_BASE}
			Shop::Pricing.class_eval { def tax(total) = total / 5 }

			class MorePricingTest < Quickdraw::Test
				test("kills its worker when mutated") do
					Process.kill(:KILL, Process.ppid) unless Shop::Pricing.new.discount(200) == 20
					assert true
				end
			end
		RUBY
		project.commit

		result = project.run("mutate", "--base", "main", "--unique-kills", "--processes", "1", "--format", "agent")

		assert_equal result.exit_status, 1
		assert_includes result.stdout, "Couldn’t find Shop::Pricing#tax (lib/pricing.rb:13) once tests had loaded, so 4 mutants didn’t run."
		assert_includes result.stdout, "10 mutants didn’t finish, since the worker running them exited."

		report = JSON.parse(project.run("mutate", "--base", "main", "--unique-kills", "--processes", "1", "--format", "json").stdout, symbolize_names: true)
		match { report => { mutants: 0, errors: 0, missing: 0, unique_kills: { errors: 10, missing: 4 } } }
	end

	test "--unique-kills says which mutants not every test ran against", timeout: 60 do
		project = unique_kills_project
		project.write("test/pricing.test.rb" => <<~RUBY)
			#{UNIQUE_BASE}
			class MorePricingTest < Quickdraw::Test
				test("exits when a discount changes") { exit!(1) unless Shop::Pricing.new.discount(300) == 30; assert true }
			end
		RUBY
		project.commit

		result = project.run("mutate", "--base", "main", "--unique-kills", "--format", "agent")

		assert_match result.stdout, /^Not every test ran against \d+ mutants?, since a test crashed, hung or didn’t load, so (its|their) tests can’t be counted as the only one to kill (it|them)\.$/
		refute_includes result.stdout, "blind"

		report = JSON.parse(project.run("mutate", "--base", "main", "--unique-kills", "--format", "json").stdout, symbolize_names: true)
		assert_operator report[:unique_kills][:incomplete], :>, 0
	end
end
