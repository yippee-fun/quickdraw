# frozen_string_literal: true

# What's changed since the last commit, staged or not, including untracked
# files, which are new in full. Paths are relative to this directory, as
# coverage is, in a repository with more than one project. Before the first
# commit, everything is untracked. Both methods return nil outside git.
module Quickdraw::Changes
	extend self

	# Without Quickdraw's own run history and reports, in case .quickdraw/ isn't ignored.
	# A rename counts as the old path deleted and the new one added, since
	# tests may still use the old one.
	def files
		untracked = git("ls-files", "--others", "--exclude-standard", "-z") or return
		changed = git("diff", "HEAD", "--relative", "--name-only", "--no-renames", "-z") || staged || ""
		(changed.split("\0") + untracked.split("\0")).uniq.reject { |path| path.start_with?(".quickdraw/") }
	end

	# { path => changed line numbers } for Ruby files.
	def lines
		untracked = git("ls-files", "--others", "--exclude-standard", "-z", "--", "*.rb") or return
		diff = git("diff", "HEAD", "--relative", "--unified=0", "--no-color", "--no-ext-diff", "--", "*.rb")
		# Before the first commit, staged files are new in full.
		untracked = "#{untracked}#{staged('*.rb')}" unless diff
		diff ||= ""
		changes = {}
		path = nil

		diff.each_line(chomp: true) do |line|
			case line
			# Git ends names with spaces with a tab, and quotes names with
			# quotes, backslashes or control characters, C style.
			in /\A\+\+\+ (?<file>.*?)\t?\z/
				file = $~[:file]
				file = file.undump if file.start_with?('"')
				path = (file == "/dev/null") ? nil : file.delete_prefix("b/")
			in /\A@@ -\S+ \+(?<start>\d+)(?:,(?<count>\d+))? @@/ if path
				start = Integer($~[:start], 10)
				count = $~[:count] ? Integer($~[:count], 10) : 1
				(changes[path] ||= []).concat((start...(start + count)).to_a)
			else nil
			end
		end

		untracked.split("\0").each do |file|
			changes[file] = Array.new(File.foreach(file).count) { |index| index + 1 }
		rescue SystemCallError
			# Such as a dangling symlink.
			nil
		end

		changes
	end

	# Files staged before the first commit, when there's nothing to diff with.
	private def staged(*pathspecs)
		git("ls-files", "--cached", "-z", "--", *pathspecs)
	end

	private def git(*arguments)
		# Without quotePath, names outside ASCII would be quoted as octal escapes.
		output = IO.popen(["git", "-c", "core.quotePath=false", *arguments], err: File::NULL, &:read)
		output if $?.success?
	rescue Errno::ENOENT
		nil
	end
end
