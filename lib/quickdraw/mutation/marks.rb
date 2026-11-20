# frozen_string_literal: true

# The comments in a file that mark mutants equivalent to the original, such as
# `# quickdraw:equivalent > → >= -- the cap below makes it the same`, which
# mutate leaves out. Without a description, it's every mutant ending on the
# line.
# Uses Prism, so it only runs in a throwaway process.
class Quickdraw::Mutation::Marks
	PATTERN = /\A#\s*quickdraw:equivalent\b(?<text>.*)\z/
	# A mark as it ends a line of code.
	COMMENT = /[ \t]*#\s*quickdraw:equivalent\b.*$/

	def initialize(path, source)
		require "prism"
		@path = path

		# { line => [text] }
		@marks = Prism.parse_comments(source).each_with_object({}) do |comment, marks|
			match = PATTERN.match(comment.slice.strip) or next
			(marks[comment.location.start_line] ||= []) << match[:text].strip
		end
	end

	# Those of `mutants` no mark covers, then those marked equivalent, as
	# [mutant, reason].
	def partition(mutants)
		equivalent = []

		kept = mutants.reject do |mutant|
			line, _text, reason = covering(mutant)
			next false unless line

			equivalent << [mutant, reason || "no reason given"]
		end

		[kept, equivalent]
	end

	# Problems with the marks on `lines` (or any line, if nil), for `mutants`.
	def warnings(mutants, lines)
		used = mutants.filter_map { |mutant| covering(mutant) }.to_h { |line, text, reason| [[line, text], reason] }
		warnings = []

		@marks.each do |line, texts|
			next unless lines.nil? || lines.include?(line)

			texts.each do |text|
				description, reason = read(text)
				reason = used[[line, text]] if used.key?([line, text])
				warnings << "#{@path}:#{line} marks a mutant equivalent without saying why. Add a reason after --." if reason.nil?
				next if used.key?([line, text])

				renamed = " Mutants that empty or remove a literal now name it, as in “\"cm\" → \"\"” or “removed b: 1”." if description in "emptied the string" | "emptied the array" | "emptied the hash" | "removed an element" | "removed a pair"
				warnings << "#{@path}:#{line} marks #{description ? "“#{description}”" : 'mutants'} equivalent, but no mutant there matches.#{renamed}"
			end
		end

		warnings
	end

	# [line, text, reason] for the mark that covers `mutant`, or nil.
	private def covering(mutant)
		mutant.line.upto(mutant.last_line) do |line|
			@marks.fetch(line, []).each do |text|
				description, reason = read(text, mutant.description)
				return [line, text, reason] if description == mutant.description || (description.nil? && line == mutant.last_line)
			end
		end

		nil
	end

	# A mark's text as [description or nil, reason or nil], for a mutant whose
	# `description` may itself contain " -- " (or, without one, at the first).
	private def read(text, description = nil)
		if description && (text == description || text.start_with?("#{description} "))
			reason = text.delete_prefix(description)[/\A\s+--\s*(.*)\z/, 1]
			return [description, reason.to_s.empty? ? nil : reason] if text == description || reason
		end

		marked, reason = text.split(/(?:\A|\s+)--\s*/, 2)
		[(marked unless marked.to_s.empty?), (reason unless reason.to_s.empty?)]
	end
end
