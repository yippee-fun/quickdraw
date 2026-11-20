# frozen_string_literal: true

require_relative "../support/integration"

class ChangesTest < Quickdraw::Test
	include Integration

	# In the project's directory, which Changes is relative to.
	def changed_lines(project, deletions: false)
		script = "require 'quickdraw'; $stdout.write(Marshal.dump(Quickdraw::Changes.lines(deletions: #{deletions})))"
		Marshal.load(IO.popen([RbConfig.ruby, "-I", File.join(Integration::ROOT, "lib"), "-e", script], chdir: project.directory, &:read))
	end

	test "takes added and deleted lines that start like file headers as lines", timeout: 20 do
		project = project(
			"a.rb" => "TEXT = <<~MARKDOWN\n-- removed\nkept\nMARKDOWN\n\ndef a = 1\n",
			"b.rb" => "x\n-- gone\n++ gone too\ny\n",
		)
		project.commit
		# Which would merge hunks, with an unchanged blank line as an empty one.
		project.git("config", "diff.interHunkContext", "10")
		project.git("config", "diff.suppressBlankEmpty", "true")
		project.write(
			"a.rb" => "TEXT = <<~MARKDOWN\n++ added\nkept\n++ more\nMARKDOWN\n\ndef a = 1\ndef b = 2\n",
			"b.rb" => "x\ny\n",
		)

		assert_equal changed_lines(project), { "a.rb" => [2, 4, 8], "b.rb" => [] }
		assert_equal changed_lines(project, deletions: true), { "a.rb" => [2, 4, 8], "b.rb" => [1.5] }
	end
end
