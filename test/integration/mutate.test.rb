# frozen_string_literal: true

require_relative "../support/integration"

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

	def commit(project)
		git = ["git", "-C", project.directory, "-c", "user.name=Quickdraw", "-c", "user.email=quickdraw@example.com", "-c", "commit.gpgsign=false"]
		system(*git, "init", "--quiet", exception: true) unless Dir.exist?(File.join(project.directory, ".git"))
		system(*git, "add", "--all", exception: true)
		system(*git, "commit", "--quiet", "--no-verify", "-m", "Commit", exception: true)
	end

	test "kills every mutant when the tests check the code", timeout: 30 do
		result = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => STRONG).run("mutate", "lib/pricing.rb", "--format", "agent")

		assert result.success?
		match { result => { stdout: /^MUTATION SCORE: 100% \(9 of 9 killed\)\. 9 mutants in [\d.]+s/ } }
		refute_includes result.stdout, "SURVIVED"
	end

	test "lists mutants no test notices, with the change and the tests that ran it", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => WEAK)
		result = project.run("mutate", "lib/pricing.rb", "--format", "agent")

		assert_equal result.exit_status, 1
		# Tests are listed fastest first.
		match { result => { stdout: %r{^SURVIVED: lib/pricing.rb:6 Shop::Pricing#discount \(> → >=\)\. Tests that ran it and passed: (.+)\n- if total > 100\n\+ if total >= 100\n} } }
		assert_equal $1.split(", ").sort, ["test/pricing.test.rb:4 PricingTest › discounts big orders", "test/pricing.test.rb:5 PricingTest › doesn't discount small orders"]
		assert_includes result.stdout, "SURVIVED: lib/pricing.rb:6 Shop::Pricing#discount (100 → 101)"
		match { result => { stdout: /^MUTATION SCORE: 66.7% \(6 of 9 killed, 3 survived\)/ } }
		assert_equal File.read(File.join(project.directory, "lib/pricing.rb")), PRICING
	end

	test "passes when the score reaches --threshold", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => WEAK)

		assert project.run("mutate", "lib/pricing.rb", "--threshold", "66").success?
		assert_equal project.run("mutate", "lib/pricing.rb", "--threshold", "67").exit_status, 1
	end

	test "reports survivors for people, and as JSON", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => WEAK)
		human = project.run("mutate", "lib/pricing.rb", "--format", "human")

		assert_includes human.stdout, "✗ lib/pricing.rb:6  > → >= in Shop::Pricing#discount\n    - if total > 100\n    + if total >= 100\n"
		match { human => { stdout: /^Mutation score 66.7% · 6 killed · 3 survived$/ } }

		require "json"
		report = JSON.parse(project.run("mutate", "lib/pricing.rb", "--format", "json").stdout, symbolize_names: true)

		match do
			report => {
				score: 66.67,
				killed: 6,
				survived: 3,
				survivors: [{ path: "lib/pricing.rb", line: 6, method: "Shop::Pricing#discount", description: "> → >=", tests: [_, _] }, *],
			}
		end
	end

	test "mutates the lines changed since the last commit", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => WEAK, ".gitignore" => ".quickdraw/\n")
		commit(project)
		project.write("lib/pricing.rb" => PRICING.sub("total / 10", "total / 20"), "test/pricing.test.rb" => WEAK.sub("), 20 }", "), 10 }"))

		result = project.run("mutate", "--format", "agent")

		assert result.success?
		match { result => { stdout: /^MUTATION SCORE: 100% \(4 of 4 killed\)/ } }
		assert_includes project.run("mutate", "lib/pricing.rb:9", "--format", "agent").stdout, "2 of 2 killed"
	end

	test "says when nothing changed", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => STRONG)
		commit(project)

		result = project.run("mutate")

		assert result.success?
		assert_equal result.stdout, "Nothing to mutate in the lines changed since the last commit.\n"
	end

	test "still reports JSON when there's nothing to mutate", timeout: 30 do
		project = project("lib/pricing.rb" => PRICING, "test/pricing.test.rb" => STRONG)
		commit(project)

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

		match { result => { exit_status: 1, stdout: /MUTATION SCORE: 100%/, stderr: /failed to load or crashed/ } }
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
		assert_includes with_map.stdout, "MUTATION SCORE: 100% (9 of 9 killed)"
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
		assert_includes result.stdout, "MUTATION SCORE: 100% (6 of 6 killed)"
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
		assert_equal result.stdout.scan(%r{^SURVIVED: lib/secrets.rb:2 Vault#code}).size, 3
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
	end
end
