# frozen_string_literal: true

# Which of a file's tests to run, from the command line: lines given as
# `path:line`, and --name and --exclude patterns. Each criterion narrows the
# selection, so they combine freely.
class Quickdraw::Filter
	REGEXP_FLAGS = { "i" => Regexp::IGNORECASE, "m" => Regexp::MULTILINE, "x" => Regexp::EXTENDED }.freeze

	# A String matches names containing it; a Regexp matches as usual.
	NamePattern = Data.define(:pattern) do
		# "/…/" with optional flags is a Regexp; anything else is a String. Raises
		# RegexpError for an invalid Regexp.
		def self.parse(argument)
			# Without a UTF-8 locale, ARGV is binary, which can't match test names.
			argument = Quickdraw.utf8(argument)

			if (match = %r{\A/(.*)/([imx]*)\z}m.match(argument))
				new(Regexp.new(match[1], match[2].chars.uniq.sum { |flag| REGEXP_FLAGS.fetch(flag) }))
			else
				new(argument)
			end
		end

		def ===(name)
			case pattern
			in String then name.include?(pattern)
			in Regexp then pattern.match?(name)
			end
		end
	end

	# `lines` maps absolute paths to the lines asked for in them. `names`,
	# `required_names` and `excludes` are NamePatterns. A test runs if it matches
	# any of `names`, all of `required_names` and none of `excludes`.
	def initialize(lines: {}, names: [], required_names: [], excludes: [])
		@lines = lines
		@names = names
		@required_names = required_names
		@excludes = excludes
	end

	def any? = @lines.any? || @names.any? || @required_names.any? || @excludes.any?

	# With its group's variant, such as the browser it ran in, if it has one.
	def self.name_of(test)
		name = [test["class_name"], test["description"]].compact.join(" › ")
		(variant = test["variant"]) ? "#{name} [#{variant}]" : name
	end

	# The indices of `tests` (as workers describe them) to run from the file at
	# the absolute `path`.
	def selected_indices(path, tests)
		indices = Array.new(tests.size) { |index| index }

		if (lines = @lines[path])
			indices &= lines.flat_map { |line| tests_at(tests, line) }
		end

		indices.select do |index|
			name = self.class.name_of(tests[index])
			(@names.empty? || @names.any? { |pattern| pattern === name }) &&
				@required_names.all? { |pattern| pattern === name } &&
				@excludes.none? { |pattern| pattern === name }
		end
	end

	# The lines asked for in `path` that no test starts at or above.
	def unmatched_lines(path, tests)
		(@lines[path] || []).select { |line| tests_at(tests, line).empty? }
	end

	# The tests starting nearest at or above `line` (usually one, but several
	# can start on the same line), as `rails test file:line` does. Ruby only
	# gives where a block starts, not where it ends.
	private def tests_at(tests, line)
		nearest = tests.map { |test| test["line"] }.select { |start| start <= line }.max
		nearest ? tests.each_index.select { |index| tests[index]["line"] == nearest } : []
	end
end
