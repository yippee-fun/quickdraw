# frozen_string_literal: true

require_relative "../support/integration"

class CoverageHTMLTest < Quickdraw::Test
	include Integration

	def setup
		super
		skip "--coverage needs fork" unless Process.respond_to?(:fork)
	end

	CALCULATOR = <<~RUBY
		class Calculator
			def add(a, b) = a + b

			def divide(a, b)
				if b == 0
					raise ArgumentError, "division by zero"
				else
					a / b
				end
			end

			def unused = :never
		end
	RUBY

	def calculator = project(
		"lib/calculator.rb" => CALCULATOR,
		"lib/orphan.rb" => "class Orphan; end\n",
		"config/quickdraw.rb" => "require_relative \"../lib/calculator\"\n",
		"test/calculator.test.rb" => <<~RUBY,
			class CalculatorTest < Quickdraw::Test
				test("adds") { assert_equal Calculator.new.add(1, 2), 3 }
				test("divides") { assert_equal Calculator.new.divide(6, 2), 3 }
			end
		RUBY
	)

	def page(project, path) = File.read(File.join(project.directory, ".quickdraw/coverage", path), encoding: Encoding::UTF_8)

	test "writes an index with the totals, files no test loaded and a link to each file's page", timeout: 20 do
		project = calculator
		result = project.run("-p", "2", "--no-history", "--coverage")

		assert result.success?
		assert_includes result.stdout, ".quickdraw/coverage/index.html · .quickdraw/coverage/lcov.info · .quickdraw/coverage/coverage.json"

		index = page(project, "index.html")
		assert_match index, %r{<h2>Lines</h2><span class="percentage medium" title="5 of 7">.*?<span class="value">71%</span>}
		assert_includes index, "<p class=\"muted\">1 of 2 covered</p>"
		assert_match index, %r{<h2>Never loaded by a test</h2>.*<code>lib/orphan.rb</code>}
		assert_includes index, "<a href=\"files/lib/calculator.rb.html\"><code>lib/calculator.rb</code></a>"
		assert_match page(project, "files/lib/calculator.rb.html"), %r{<a href="../../index.html">}
	end

	test "marks each line of a file's page with its count, and the branches and methods that never ran", timeout: 20 do
		project = calculator
		project.run("-p", "1", "--no-history", "--coverage")

		file = page(project, "files/lib/calculator.rb.html")
		assert_includes file, "<tr id=\"L5\" class=\"covered\"><td class=\"number\"><a href=\"#L5\">5</a></td><td class=\"hits\">1</td>"
		assert_includes file, "<tr id=\"L6\" class=\"uncovered\"><td class=\"number\"><a href=\"#L6\">6</a></td><td class=\"hits\">0</td>"
		assert_includes file, "<span class=\"note\">then never taken</span>"
		assert_includes file, "<tr id=\"L7\"><td class=\"number\"><a href=\"#L7\">7</a></td><td class=\"hits\"></td>"
		assert_includes file, "<dt>Not run</dt><dd><span class=\"lines\"><a href=\"#L6\">6</a><a href=\"#L12\">12</a></span></dd>"
		assert_includes file, "<a href=\"#L12\"><code>Calculator#unused</code></a>"
	end

	test "emphasises changed lines no test ran", timeout: 20 do
		project = calculator
		git = -> (*arguments) { system("git", "-C", project.directory, "-c", "user.name=Quickdraw", "-c", "user.email=quickdraw@example.com", "-c", "commit.gpgsign=false", *arguments, exception: true) }
		git.("init", "--quiet")
		git.("add", "--all")
		git.("commit", "--quiet", "--no-verify", "-m", "Calculator")
		project.write("lib/calculator.rb" => CALCULATOR.sub("def unused = :never", "def unused = :never\n\tdef subtract(a, b) = a - b"))

		project.run("-p", "1", "--no-history", "--coverage")

		assert_match page(project, "index.html"), %r{<h2>Changed lines</h2>.*<a href="files/lib/calculator.rb.html#L13">13</a>}
		file = page(project, "files/lib/calculator.rb.html")
		assert_includes file, "<tr id=\"L13\" class=\"uncovered changed\">"
		assert_includes file, "<dt>Changed, not run</dt><dd><span class=\"lines\"><a href=\"#L13\">13</a></span></dd>"
	end

	test "escapes the source", timeout: 20 do
		project = calculator
		project.write("lib/calculator.rb" => CALCULATOR.sub("def unused = :never", %(def unused = "<script>&amp;</script>")))

		project.run("-p", "1", "--no-history", "--coverage")

		file = page(project, "files/lib/calculator.rb.html")
		assert_includes file, "def unused = &quot;&lt;script&gt;&amp;amp;&lt;/script&gt;&quot;"
		refute_includes file, "<script>"
	end

	test "says when a file no longer exists", timeout: 20 do
		project = calculator
		project.write("test/delete.test.rb" => "class DeleteTest < Quickdraw::Test; test('deletes') { File.delete('lib/calculator.rb'); assert true }; end\n")

		project.run("-p", "1", "--no-history", "--coverage")

		assert_includes page(project, "files/lib/calculator.rb.html"), "lib/calculator.rb no longer exists"
	end

	test "warns when a file changed after tests loaded it", timeout: 20 do
		project = calculator
		project.write("test/change.test.rb" => "class ChangeTest < Quickdraw::Test; test('changes') { File.write('lib/calculator.rb', \"# New\\n\", mode: 'a'); assert true }; end\n")

		project.run("-p", "1", "--no-history", "--coverage")

		assert_includes page(project, "files/lib/calculator.rb.html"), "lib/calculator.rb has changed since tests loaded it"
	end

	test "test processes don't load Phlex with --coverage", timeout: 20 do
		project = calculator
		project.write("test/phlex.test.rb" => "class PhlexTest < Quickdraw::Test; test('no Phlex') { refute defined?(::Phlex) }; end\n")

		result = project.run("-p", "2", "--no-history", "--coverage")

		assert result.success?
		assert File.exist?(File.join(project.directory, ".quickdraw/coverage/index.html"))
	end
end
