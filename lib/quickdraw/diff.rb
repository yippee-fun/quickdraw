# frozen_string_literal: true

module Quickdraw
	module Diff
		MAX_MATCHES = 1_000_000

		# Above a diff of expected (old) against actual (new) text.
		LEGEND = "\e[31m- Expected\e[0m  \e[32m+ Actual\e[0m"

		# Where in a text a match starts, from 0, and its line and column, from 1.
		Location = Data.define(:start, :line, :column)

		# Needles longer than this are placed by trigrams alone, since aligning
		# them a character at a time takes the square of their length.
		ALIGNABLE = 200

		extend self

		# Where `text` is most like `needle`, or nil if they share nothing. Each
		# window of the needle's length is scored by how many of its trigrams are
		# also the needle's, or of its characters if no trigram is, as when a
		# short needle has a typo in the middle, then the best is aligned a
		# character at a time. In one pass, keeping only a window's scores.
		def closest(text, needle, gram = [3, needle.size, text.size].min)
			return if gram == 0

			grams = needle.each_char.each_cons(gram).to_h { |chars| [chars.join, true] }
			width = needle.size - gram + 1
			window = []
			score = 0
			best_score = 0
			best = 0

			text.each_char.each_cons(gram).with_index do |chars, index|
				hit = grams.key?(chars.join) ? 1 : 0
				window << hit
				score += hit - ((window.size > width) ? window.shift : 0)
				next unless score > best_score

				best = index - window.size + 1
				best_score = score
			end

			if best_score == 0
				return (gram > 1) ? closest(text, needle, 1) : nil
			end

			location(text, (needle.size > ALIGNABLE) ? best : align(text, needle.chars, best))
		end

		def location(text, start)
			before = text[0, start]
			line_start = before.rindex("\n")&.+(1) || 0
			Location.new(start:, line: before.count("\n") + 1, column: start - line_start + 1)
		end

		# The start near `start` where the most characters equal the needle's.
		private def align(text, needle, start)
			first = [start - needle.size, 0].max
			# Only the region it can be in, as indexing text that isn't ASCII is linear.
			region = text[first, needle.size * 3].chars

			offset = region.each_index.max_by do |candidate|
				[needle.each_with_index.count { |char, index| region[candidate + index] == char }, -candidate]
			end

			first + offset
		end

		# Computes a diff between two strings.
		# @param old_text [String] The original/baseline text (e.g., expected)
		# @param new_text [String] The changed text (e.g., actual)
		# @return [String] Formatted diff with - for removals and + for additions
		def diff(old_text, new_text)
			old_lines = old_text.to_s.lines(chomp: true)
			new_lines = new_text.to_s.lines(chomp: true)

			changes = patience_diff(old_lines, new_lines)
			format_changes(changes)
		end

		# Patience Diff Algorithm
		# 1. Find unique lines that appear in both sequences
		# 2. Find the longest common subsequence of those unique lines
		# 3. Recursively diff between the matched unique lines
		private def patience_diff(old_lines, new_lines)
			return additions(new_lines, 0) if old_lines.empty?
			return deletions(old_lines, 0) if new_lines.empty?

			prefix = 0
			prefix += 1 while prefix < old_lines.size && prefix < new_lines.size && old_lines[prefix] == new_lines[prefix]
			suffix = 0
			suffix += 1 while suffix < old_lines.size - prefix && suffix < new_lines.size - prefix && old_lines[-1 - suffix] == new_lines[-1 - suffix]

			if prefix > 0 || suffix > 0
				middle = patience_diff(old_lines[prefix...(old_lines.size - suffix)], new_lines[prefix...(new_lines.size - suffix)])
				return old_lines.first(prefix).map { |line| [:equal, line] } + middle + old_lines.last(suffix).map { |line| [:equal, line] }
			end

			# Find unique lines in both sequences
			unique_old = find_unique_lines(old_lines)
			unique_new = find_unique_lines(new_lines)

			# Find common unique lines (these are our anchors)
			common_unique = unique_old.keys & unique_new.keys

			if common_unique.empty?
				# No unique common lines - fall back to LCS on all lines
				lcs_diff(old_lines, new_lines)
			else
				# Build list of matching positions for unique lines
				matches = common_unique.map { |line| [unique_old[line], unique_new[line]] }
				matches.sort_by!(&:first)

				# Find longest increasing subsequence of new positions
				anchors = longest_increasing_subsequence(matches)

				# Recursively diff between anchors
				diff_with_anchors(old_lines, new_lines, anchors)
			end
		end

		private def find_unique_lines(lines)
			counts = Hash.new(0)
			positions = {}

			lines.each_with_index do |line, idx|
				counts[line] += 1
				positions[line] = idx
			end

			# Keep only lines that appear exactly once
			positions.select { |line, _| counts[line] == 1 }
		end

		private def longest_increasing_subsequence(matches)
			return matches if matches.length <= 1

			# Standard LIS algorithm using binary search
			n = matches.length
			# tails[i] = smallest ending value of all increasing subsequences of length i+1
			tails = []
			# predecessors[i] = index of predecessor of matches[i] in the LIS
			predecessors = Array.new(n)
			# indices[i] = index in matches of the element at tails[i]
			indices = []

			matches.each_with_index do |(old_pos, new_pos), i|
				# Binary search for position in tails
				pos = tails.bsearch_index { |t| t >= new_pos } || tails.length

				tails[pos] = new_pos
				indices[pos] = i
				predecessors[i] = (pos > 0) ? indices[pos - 1] : nil
			end

			# Reconstruct LIS
			result = []
			idx = indices[tails.length - 1]
			while idx
				result.unshift(matches[idx])
				idx = predecessors[idx]
			end

			result
		end

		private def diff_with_anchors(old_lines, new_lines, anchors)
			changes = []
			old_pos = 0
			new_pos = 0

			anchors.each do |(anchor_old, anchor_new)|
				# Diff the section before this anchor
				old_section = old_lines[old_pos...anchor_old]
				new_section = new_lines[new_pos...anchor_new]

				changes.concat(patience_diff(old_section, new_section))

				# Add the anchor as unchanged
				changes << [:equal, old_lines[anchor_old]]

				old_pos = anchor_old + 1
				new_pos = anchor_new + 1
			end

			# Diff remaining section after last anchor
			old_section = old_lines[old_pos..]
			new_section = new_lines[new_pos..]
			changes.concat(patience_diff(old_section, new_section))

			changes
		end

		# Fallback to standard LCS-based diff
		private def lcs_diff(old_lines, new_lines)
			lcs = longest_common_subsequence(old_lines, new_lines)
			changes = []

			old_pos = 0
			new_pos = 0

			lcs.each do |(old_idx, new_idx)|
				# Deletions before this match
				while old_pos < old_idx
					changes << [:delete, old_lines[old_pos]]
					old_pos += 1
				end

				# Additions before this match
				while new_pos < new_idx
					changes << [:insert, new_lines[new_pos]]
					new_pos += 1
				end

				# The match itself
				changes << [:equal, old_lines[old_pos]]
				old_pos += 1
				new_pos += 1
			end

			# Remaining deletions
			while old_pos < old_lines.length
				changes << [:delete, old_lines[old_pos]]
				old_pos += 1
			end

			# Remaining additions
			while new_pos < new_lines.length
				changes << [:insert, new_lines[new_pos]]
				new_pos += 1
			end

			changes
		end

		private def longest_common_subsequence(old_lines, new_lines)
			return [] if old_lines.empty? || new_lines.empty?

			new_positions = {}
			new_lines.each_with_index { |line, idx| (new_positions[line] ||= []) << idx }

			# Many repeated lines would make a quadratic number of matches.
			return [] if old_lines.sum { |line| new_positions[line]&.size || 0 } > MAX_MATCHES

			# Each old line's matches in descending order, so the increasing
			# subsequence takes at most one of them.
			matches = []
			old_lines.each_with_index do |line, old_idx|
				new_positions[line]&.reverse_each { |new_idx| matches << [old_idx, new_idx] }
			end

			longest_increasing_subsequence(matches)
		end

		private def additions(lines, _start_pos)
			lines.map { |line| [:insert, line] }
		end

		private def deletions(lines, _start_pos)
			lines.map { |line| [:delete, line] }
		end

		private def format_changes(changes)
			return "" if changes.all? { |(type, _)| type == :equal }

			lines = []
			changes.each do |(type, content)|
				case type
				when :equal
					lines << "  #{content}"
				when :delete
					lines << "\e[31m- #{content}\e[0m"
				when :insert
					lines << "\e[32m+ #{content}\e[0m"
				end
			end

			lines.join("\n")
		end
	end
end
