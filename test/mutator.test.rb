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
			["&& → ||", "return a.first if a.any? || b != 1"],
			["any? → none?", "return a.first if a.none? && b != 1"],
			["!= → ==", "return a.first if a.any? && b == 1"],
			["1 → 2", "return a.first if a.any? && b != 2"],
			["1 → 0", "return a.first if a.any? && b != 0"],
			["first → last", "return a.last if a.any? && b != 1"],
			["negated the condition", "!(a + b < 2) ? true : false"],
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

	test "raises on a syntax error" do
		assert_raises(SyntaxError) { mutants("class A; def b(; end") }
	end
end
