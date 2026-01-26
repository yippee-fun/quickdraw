# frozen_string_literal: true

module Quickdraw
	module Diff
		class << self
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

			private

			# Patience Diff Algorithm
			# 1. Find unique lines that appear in both sequences
			# 2. Find the longest common subsequence of those unique lines
			# 3. Recursively diff between the matched unique lines
			def patience_diff(old_lines, new_lines)
				return additions(new_lines, 0) if old_lines.empty?
				return deletions(old_lines, 0) if new_lines.empty?

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

			def find_unique_lines(lines)
				counts = Hash.new(0)
				positions = {}

				lines.each_with_index do |line, idx|
					counts[line] += 1
					positions[line] = idx
				end

				# Keep only lines that appear exactly once
				positions.select { |line, _| counts[line] == 1 }
			end

			def longest_increasing_subsequence(matches)
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

			def diff_with_anchors(old_lines, new_lines, anchors)
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
			def lcs_diff(old_lines, new_lines)
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

			def longest_common_subsequence(old_lines, new_lines)
				return [] if old_lines.empty? || new_lines.empty?

				# Build a hash of new_lines positions for quick lookup
				new_positions = Hash.new { |h, k| h[k] = [] }
				new_lines.each_with_index { |line, idx| new_positions[line] << idx }

				# Find matches
				matches = []
				old_lines.each_with_index do |line, old_idx|
					new_positions[line].each do |new_idx|
						matches << [old_idx, new_idx]
					end
				end

				return [] if matches.empty?

				# Sort by old position, then by new position
				matches.sort!

				# Find LIS by new position
				lis_matches(matches)
			end

			def lis_matches(matches)
				return matches if matches.length <= 1

				n = matches.length
				tails = []
				indices = []
				predecessors = Array.new(n)

				matches.each_with_index do |(old_pos, new_pos), i|
					pos = tails.bsearch_index { |t| t >= new_pos } || tails.length

					tails[pos] = new_pos
					indices[pos] = i
					predecessors[i] = (pos > 0) ? indices[pos - 1] : nil
				end

				result = []
				idx = indices[tails.length - 1]
				while idx
					result.unshift(matches[idx])
					idx = predecessors[idx]
				end

				result
			end

			def additions(lines, _start_pos)
				lines.map { |line| [:insert, line] }
			end

			def deletions(lines, _start_pos)
				lines.map { |line| [:delete, line] }
			end

			def format_changes(changes)
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
end
