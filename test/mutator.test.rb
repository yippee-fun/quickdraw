# frozen_string_literal: true

class MutatorTest < Quickdraw::Test
	def mutants(source, lines: nil)
		Quickdraw::Mutation::Mutator.new("/project/lib/example.rb", source, relative_path: "lib/example.rb").call(lines:)
	end

	def changes(source)
		mutants(source).map { |mutant| [mutant.description, mutant.after.strip] }
	end

	test "swaps operators, literals and methods, and negates conditions" do
		source = <<~RUBY
			class Example
				def call(a, b)
					return a.first if a.any? && b != 1
					a + b < 2 ? true : false
				end
			end
		RUBY

		assert_equal changes(source), [
			["replaced the body with nil", "nil"],
			["removed the statement", "nil"],
			["negated the condition", "return a.first if !(a.any? && b != 1)"],
			# Not to false, which is removing the statement.
			["condition → true", "return a.first if true"],
			["&& → ||", "return a.first if a.any? || b != 1"],
			["a && b → a", "return a.first if a.any?"],
			["a && b → b", "return a.first if b != 1"],
			["any? → none?", "return a.first if a.none? && b != 1"],
			["any? → all?", "return a.first if a.all? && b != 1"],
			["!= → ==", "return a.first if a.any? && b == 1"],
			["1 → 2", "return a.first if a.any? && b != 2"],
			["1 → 0", "return a.first if a.any? && b != 0"],
			["removed the return value", "return if a.any? && b != 1"],
			["first → last", "return a.last if a.any? && b != 1"],
			["negated the condition", "!(a + b < 2) ? true : false"],
			["condition → true", "true ? true : false"],
			["condition → false", "false ? true : false"],
			["< → <=", "a + b <= 2 ? true : false"],
			["+ → -", "a - b < 2 ? true : false"],
			["2 → 3", "a + b < 3 ? true : false"],
			["2 → 0", "a + b < 0 ? true : false"],
			["true → false", "a + b < 2 ? false : false"],
			["false → true", "a + b < 2 ? true : true"],
		]
	end

	test "keeps the encoding the source declares, and shows the change in UTF-8" do
		source = "# encoding: iso-8859-1\nclass Example\n\tdef call(a) = a ? \"caf\xE9\" : \"th\xE9\"\nend\n"

		assert_equal changes(source), [
			["replaced the body with nil", "def call(a) = nil"],
			["negated the condition", "def call(a) = !(a) ? \"café\" : \"thé\""],
			["condition → true", "def call(a) = true ? \"café\" : \"thé\""],
			["condition → false", "def call(a) = false ? \"café\" : \"thé\""],
			["emptied the string", "def call(a) = a ? \"\" : \"thé\""],
			["emptied the string", "def call(a) = a ? \"café\" : \"\""],
		]
		assert_equal mutants(source).map { |mutant| mutant.source.encoding }.uniq, [Encoding::ISO_8859_1]
	end

	test "labels methods in UTF-8 whatever the source's encoding" do
		source = "# encoding: iso-8859-1\nclass Example\n\tdef caf\xE9(a) = a + 1\nend\n"

		assert_equal mutants(source).map { |mutant| mutant.subject.label }.uniq, ["Example#café"]
	end

	test "skips mutations that can't change behaviour or only break the method" do
		source = <<~RUBY
			module Example
				def self.call(a)
					total = a * 1
					"x" + a
					!a.nil?
				end
			end
		RUBY

		assert_equal changes(source), [
			["replaced the body with nil", "nil"],
			["1 → 2", "total = a * 2"],
			["1 → 0", "total = a * 0"],
			["removed the statement", "nil"],
			["emptied the string", "\"\" + a"],
			["removed the negation", "a.nil?"],
		]
	end

	test "only mutates methods in classes, modules and class << self" do
		source = <<~RUBY
			RATE = 1
			Data.define(:a) { def b = 1 }

			module Outer
				class Inner
					class << self
						private def one = 1
					end
				end
			end
		RUBY

		subjects = mutants(source).map(&:subject).uniq

		assert_equal subjects.map(&:label), ["Outer::Inner.one"]
		assert_equal subjects.first.nesting, [["module", "Outer"], ["class", "Inner"], ["class", "<< self"]]
		assert_equal subjects.first.id, "lib/example.rb:7:11"
	end

	test "mutates only what touches the lines given, and knows each mutant's statement" do
		source = <<~RUBY
			class Example
				def call(a)
					puts(a)
					[
						a + 1,
					]
				end
			end
		RUBY

		assert_equal mutants(source, lines: [5]).map { |mutant| [mutant.description, mutant.line, mutant.covering_line] }, [
			["replaced the body with nil", 3, 2],
			["emptied the array", 4, 4],
			["+ → -", 5, 4],
			["1 → 2", 5, 4],
			["1 → 0", 5, 4],
		]
	end

	test "doesn't remove a statement that holds a local variable's only assignment" do
		source = <<~RUBY
			class Example
				def call(ok)
					if ok
						result = 3
					end
					log(ok)
					result
				end
			end
		RUBY

		assert_equal mutants(source).select { |mutant| mutant.description == "removed the statement" }.map(&:line), [6]
	end

	test "keeps the lines after a removed statement where they were" do
		source = <<~RUBY
			class Example
				def call
					log(
						1,
					)
					__LINE__
				end
			end
		RUBY

		removal = mutants(source).find { |mutant| mutant.description == "removed the statement" }

		assert_equal removal.source.lines.size, 6
		assert_equal removal.after, "\t\tnil"
	end

	test "gives methods on the same line their own subjects" do
		subjects = mutants("class A; def b = 1; def c = 2; end\n").map(&:subject).uniq

		assert_equal subjects.map(&:id), ["lib/example.rb:1:9", "lib/example.rb:1:20"]
	end

	test "keeps whether string literals are frozen" do
		assert mutants("# frozen_string_literal: true\nclass A; def b = 1; end\n").all?(&:frozen_string_literal)
		refute mutants("class A; def b = 1; end\n").any?(&:frozen_string_literal)
	end

	test "replaces conditions with true and false, and && and || with either side" do
		source = <<~RUBY
			class Example
				def call(a, b)
					log(a) if a
					count += 1 while b
					return 1 unless a || b
					a ? 2 : 3
				end

				def wait(job)
					sleep until job.done?
				end

				def pick(a)
					case a
					in Integer if a.positive? then a
					end
				end
			end
		RUBY

		# Not making an `if`, `unless` or loop whose value isn't used do
		# nothing, which is removing its statement.
		assert_equal changes(source), [
			["replaced the body with nil", "nil"],
			["removed the statement", "nil"],
			["negated the condition", "log(a) if !(a)"],
			["condition → true", "log(a) if true"],
			["removed the statement", "nil"],
			["+= → -=", "count -= 1 while b"],
			["1 → 2", "count += 2 while b"],
			["1 → 0", "count += 0 while b"],
			["removed the statement", "nil"],
			["negated the condition", "return 1 unless !(a || b)"],
			["condition → false", "return 1 unless false"],
			["|| → &&", "return 1 unless a && b"],
			["a || b → a", "return 1 unless a"],
			["a || b → b", "return 1 unless b"],
			["removed the return value", "return unless a || b"],
			["1 → 2", "return 2 unless a || b"],
			["1 → 0", "return 0 unless a || b"],
			["negated the condition", "!(a) ? 2 : 3"],
			["condition → true", "true ? 2 : 3"],
			["condition → false", "false ? 2 : 3"],
			["2 → 3", "a ? 3 : 3"],
			["2 → 0", "a ? 0 : 3"],
			["3 → 4", "a ? 2 : 4"],
			["3 → 0", "a ? 2 : 0"],
			["replaced the body with nil", "nil"],
			["condition → true", "sleep until true"],
			["replaced the body with nil", "nil"],
			["negated the condition", "in Integer if !(a.positive?) then a"],
			["condition → true", "in Integer if true then a"],
			["condition → false", "in Integer if false then a"],
			["positive? → negative?", "in Integer if a.negative? then a"],
		]
	end

	test "stops a loop whose body runs before its condition, though it's a statement on its own" do
		source = "class A\n\tdef b(job)\n\t\tbegin\n\t\t\tjob.run\n\t\tend while job.failed?\n\t\tjob\n\tend\nend\n"

		assert_includes changes(source), ["condition → false", "end while false"]
	end

	test "removes arguments, but not ones the method requires or has as its default" do
		source = <<~RUBY
			class Example
				def call(a)
					helper(a, 2, 3, k: 1, r: a, &a)
					join(a)
					a.round(2)
					a.zip(a)
					puts a
					log k: a
				end

				def helper(x, y, z = 3, k: 1, r:) = x
			end
		RUBY

		removals = mutants(source).select { |mutant| mutant.description == "removed an argument" }

		# Not z's default, k's default or the required r; not a.zip's argument, which
		# is required, nor puts's, which is unknown.
		assert_equal removals.map { |mutant| mutant.after.strip }, [
			"helper(2, 3, k: 1, r: a, &a)",
			"helper(a, 3, k: 1, r: a, &a)",
			"helper(a, 2, 3, k: 1, r: a)",
			"join()",
			"a.round()",
			"log",
		]
	end

	test "removes arguments only where every definition of the method can do without them" do
		source = <<~RUBY
			class A
				def call(x, callback)
					helper(8)
					other(20, x)
					tap(&callback)
					items.join(<<~SEPARATOR)
						separator
					SEPARATOR
				end

				def helper(x) = x
				def other(x, y = x) = y
			end

			class B
				def helper(x = 10) = x
			end
		RUBY

		# Not helper's argument, which A#helper requires, tap's block, or a heredoc,
		# whose body would be left behind, but other's, whose default isn't x here.
		assert_equal mutants(source).select { |mutant| mutant.description == "removed an argument" }.map { |mutant| mutant.after.strip }, ["other(x)", "other(20)"]
	end

	test "doesn't mutate default arguments, which tests that pass them don't run" do
		assert_equal mutants("class A\n\tdef b(c,\n\t\td = 3) = c\nend\n").map(&:description), ["replaced the body with nil"]
	end

	test "knows the lines that run for rescue and ensure bodies, and a case without a subject" do
		source = <<~RUBY
			class A
				def call(a)
					case
					when a then 1
					when b then 2
					end
					risky
				ensure
					begin
						cleanup
					end
				end
			end
		RUBY

		covering = mutants(source).to_h { |mutant| [mutant.description, mutant.covering_line] }

		assert_equal covering.values_at("removed the when branch", "removed the ensure body", "removed the statement"), [4, 10, 4]
	end

	test "swaps ||= on a local only if it may already have a value, and keeps &. in fetch" do
		source = <<~RUBY
			class A
				def call(options)
					value = options[:value]
					value ||= 1
					fresh ||= 2
					options&.fetch(:key)
				end
			end
		RUBY

		descriptions = mutants(source).map { |mutant| [mutant.description, mutant.after.strip] }

		assert_includes descriptions, ["||= → =", "value = 1"]
		refute_includes descriptions, ["||= → =", "fresh = 2"]
		refute descriptions.any? { |description, _| description == "fetch → []" }
	end

	test "drops calls, blocks and safe navigation, and swaps methods" do
		source = <<~'RUBY'
			class Example
				def call(a)
					a.each { log(it) }
					tap { log(a) }
					"x".to_s + "#{a.to_s}"
					a&.strip.sort_by { it }.reverse_each { log(it) }
					a.map { it * 2 }
					a.fetch(:b)
				end
			end
		RUBY

		# Not removing tap's block, which it needs, nor to_s from a string or
		# interpolation, nor map to each where the value isn't used.
		assert_equal changes(source), [
			["replaced the body with nil", "nil"],
			["removed the statement", "nil"],
			["removed the block", "a.each"],
			["removed the statement", "nil"],
			["removed the statement", "nil"],
			["emptied the string", "\"\".to_s + \"\#{a.to_s}\""],
			["emptied the string", "\"x\".to_s + \"\""],
			["removed the statement", "nil"],
			["reverse_each → each", "a&.strip.sort_by { it }.each { log(it) }"],
			["removed the block", "a&.strip.sort_by { it }.reverse_each"],
			["removed .sort_by", "a&.strip.reverse_each { log(it) }"],
			["removed the block", "a&.strip.sort_by.reverse_each { log(it) }"],
			["&. → .", "a.strip.sort_by { it }.reverse_each { log(it) }"],
			["removed .strip", "a.sort_by { it }.reverse_each { log(it) }"],
			["removed the statement", "nil"],
			["removed the block", "a.map"],
			["* → /", "a.map { it / 2 }"],
			["2 → 3", "a.map { it * 3 }"],
			["2 → 0", "a.map { it * 0 }"],
			["fetch → []", "a[:b]"],
		]
	end

	test "empties and shortens literals" do
		source = <<~'RUBY'
			class Example
				def call(a)
					log("", "x#{a}", <<~TEXT)
						heredoc
					TEXT
					log([1, a], { b: 1, c: a }, :symbol, 1.5)
					log(1..a, 1.., a =~ /x/)
				end
			end
		RUBY

		# Not empty strings, heredocs, symbols or endless ranges, nor removing the
		# first statement, which would leave the heredoc's body behind.
		assert_equal changes(source), [
			["replaced the body with nil", "nil"],
			["emptied the string", "log(\"\", \"\", <<~TEXT)"],
			["removed the statement", "nil"],
			["emptied the array", "log([], { b: 1, c: a }, :symbol, 1.5)"],
			["removed an element", "log([a], { b: 1, c: a }, :symbol, 1.5)"],
			["removed an element", "log([1], { b: 1, c: a }, :symbol, 1.5)"],
			["1 → 2", "log([2, a], { b: 1, c: a }, :symbol, 1.5)"],
			["1 → 0", "log([0, a], { b: 1, c: a }, :symbol, 1.5)"],
			["emptied the hash", "log([1, a], {}, :symbol, 1.5)"],
			["removed a pair", "log([1, a], { c: a }, :symbol, 1.5)"],
			["removed a pair", "log([1, a], { b: 1 }, :symbol, 1.5)"],
			["1 → 2", "log([1, a], { b: 2, c: a }, :symbol, 1.5)"],
			["1 → 0", "log([1, a], { b: 0, c: a }, :symbol, 1.5)"],
			["1.5 → 2.5", "log([1, a], { b: 1, c: a }, :symbol, 2.5)"],
			["1.5 → 0.0", "log([1, a], { b: 1, c: a }, :symbol, 0.0)"],
			[".. → ...", "log(1...a, 1.., a =~ /x/)"],
			["1 → 2", "log(2..a, 1.., a =~ /x/)"],
			["1 → 0", "log(0..a, 1.., a =~ /x/)"],
			["1 → 2", "log(1..a, 2.., a =~ /x/)"],
			["1 → 0", "log(1..a, 0.., a =~ /x/)"],
			["regexp → never matches", "log(1..a, 1.., a =~ /(?!)/)"],
		]
	end

	test "drops branches, rescues, ensures, and the values of jumps, super and yield" do
		source = <<~RUBY
			class Example < Base
				def call(a)
					case a
					in Integer then :number
					in String then :text
					end
					risky rescue fallback
					a.each { |b| next b if b; break nil }
					super(a, b)
					return a
				ensure
					yield(a)
				end

				def other
					super
				end

				def third(a)
					super
				rescue Error
					retry_later(a)
				end
			end
		RUBY

		assert_equal mutants(source).map { |mutant| [mutant.description, mutant.after.strip, mutant.covering_line] }, [
			["replaced the body with nil", "nil", 2],
			["removed the statement", "nil", 3],
			["removed the in branch", "", 3],
			["removed the in branch", "", 3],
			["removed the statement", "nil", 7],
			["removed the rescue", "risky", 7],
			["rescued value → nil", "risky rescue nil", 7],
			["removed the statement", "nil", 8],
			["removed the block", "a.each", 8],
			["removed the statement", "a.each { |b| nil; break nil }", 8],
			["negated the condition", "a.each { |b| next b if !(b); break nil }", 8],
			["condition → true", "a.each { |b| next b if true; break nil }", 8],
			["removed the next value", "a.each { |b| next if b; break nil }", 8],
			["removed the statement", "nil", 9],
			["super(…) → super()", "super()", 9],
			["removed the return value", "return", 10],
			# Only for the tests that run the ensure or rescue body.
			["removed the ensure body", "nil", 12],
			["removed the yield arguments", "yield", 12],
			# Not `super` to `super()` in a method without parameters.
			["replaced the body with nil", "nil", 15],
			["replaced the body with nil", "nil", 19],
			["super → super()", "super()", 20],
			["replaced the rescue body with nil", "nil", 22],
		]
	end

	test "swaps compound assignments, and ||= to =" do
		source = <<~RUBY
			class Example
				def call(a, b = nil)
					@total += a
					@total *= 1
					@name += "x"
					@cache ||= {}
					b ||= []
					c ||= 1
					@cache[a] ||= c
				end
			end
		RUBY

		# Not `*= 1` to `/= 1`, `+=` on a string, or `||=` on a local that's nil before it.
		assert_equal changes(source), [
			["replaced the body with nil", "nil"],
			["removed the statement", "nil"],
			["+= → -=", "@total -= a"],
			["removed the statement", "nil"],
			["1 → 2", "@total *= 2"],
			["1 → 0", "@total *= 0"],
			["removed the statement", "nil"],
			["emptied the string", "@name += \"\""],
			["removed the statement", "nil"],
			["||= → =", "@cache = {}"],
			["||= → =", "b = []"],
			["1 → 2", "c ||= 2"],
			["1 → 0", "c ||= 0"],
			["||= → =", "@cache[a] = c"],
		]
	end

	test "raises on a syntax error" do
		assert_raises(SyntaxError) { mutants("class A; def b(; end") }
	end
end
