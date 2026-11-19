# frozen_string_literal: true

# The test file for a source file, or the source file for a test, so an editor
# can jump between them: `$EDITOR $(quickdraw counterpart lib/user.rb)`.
#
# Looks beside the file, then in the matching place under the usual
# directories, then for the most similar file with the same name.
class Quickdraw::Commands::Counterpart
	TEST_DIRECTORIES = ["test", "tests", "spec", "specs"].freeze
	SOURCE_DIRECTORIES = ["app", "lib", "src"].freeze
	TEST_SUFFIX = ".test.rb"

	def initialize(args = [], io: $stdout)
		@args = args
		@io = io
	end

	def call
		case @args
		in [path] if File.file?(path)
			if (counterpart = find(path.delete_prefix("#{Dir.pwd}/").delete_prefix("./")))
				@io.puts counterpart
				0
			else
				warn "No counterpart found for #{path}."
				1
			end
		in [path]
			warn "#{path} doesn’t exist."
			2
		else
			warn "Usage: #{Quickdraw::Reporters.command} counterpart PATH"
			2
		end
	end

	# `path` is relative to the current directory.
	def find(path)
		path.end_with?(TEST_SUFFIX) ? source_for(path) : test_for(path)
	end

	# test/models/user.test.rb: test/models/user.rb, then app/models/user.rb,
	# lib/models/user.rb, lib/*/models/user.rb and so on.
	private def source_for(path)
		relative = "#{without_root(path, TEST_DIRECTORIES).delete_suffix(TEST_SUFFIX)}.rb"

		candidates = [
			"#{path.delete_suffix(TEST_SUFFIX)}.rb",
			*SOURCE_DIRECTORIES.flat_map { |directory| [File.join(directory, relative), *Dir.glob(File.join(directory, "*", relative))] },
		]

		candidates.find { |candidate| File.file?(candidate) } ||
			closest(relative, Dir.glob("{#{SOURCE_DIRECTORIES.join(',')}}/**/*.rb").reject { |file| file.end_with?(TEST_SUFFIX) })
	end

	# lib/quickdraw/inspector.rb: lib/quickdraw/inspector.test.rb, then
	# test/quickdraw/inspector.test.rb, test/inspector.test.rb and so on.
	private def test_for(path)
		relative = without_root(path, SOURCE_DIRECTORIES).delete_suffix(".rb")
		# Without the directory named after the project, as in lib/quickdraw/.
		relatives = [relative, relative.split("/", 2)[1]].compact

		candidates = [
			"#{path.delete_suffix('.rb')}#{TEST_SUFFIX}",
			*TEST_DIRECTORIES.product(relatives).map { |directory, name| File.join(directory, "#{name}#{TEST_SUFFIX}") },
		]

		candidates.find { |candidate| File.file?(candidate) } ||
			closest(relative, Dir.glob("**/*#{TEST_SUFFIX}").grep_v(Quickdraw::CLI::IGNORED_DIRECTORIES))
	end

	private def without_root(path, roots)
		root, rest = path.split("/", 2)
		(rest && roots.include?(root)) ? rest : path
	end

	# Among files with the same name, the one whose path shares the most with
	# `relative`, or nil if none has the same name.
	private def closest(relative, files)
		name = File.basename(relative).delete_suffix(".rb")
		same_name = files.select { |file| File.basename(file).delete_suffix(".rb").delete_suffix(".test") == name }
		same_name.max_by { |file| (trigrams(file) & trigrams(relative)).size }
	end

	private def trigrams(text)
		text.each_char.each_cons(3).map(&:join).uniq
	end
end
