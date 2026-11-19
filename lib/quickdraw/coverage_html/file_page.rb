# frozen_string_literal: true

# A file's source, each line marked with how many times it ran. `data` is the
# file's entry in CoverageReport#as_json and `changed` lists its changed lines
# that didn't run.
class Quickdraw::CoverageHTML::FilePage < Phlex::HTML
	def initialize(summary, data, changed:)
		@summary = summary
		@data = data
		@changed = changed
	end

	def view_template
		render Quickdraw::CoverageHTML::Layout.new(title: "#{@summary.path} · Coverage") do
			nav { a(href: "#{'../' * (@summary.path.count('/') + 1)}index.html") { "← Coverage" } }
			h1 { code { @summary.path } }

			section(class: "totals") do
				render Quickdraw::CoverageHTML::Total.new("Lines", @summary.lines)
				render Quickdraw::CoverageHTML::Total.new("Branches", @summary.branches)
				render Quickdraw::CoverageHTML::Total.new("Methods", @summary.methods)
			end

			problems
			source
		end
	end

	private def problems
		never_called = @data["methods"].select { |method| method["count"] == 0 }.sort_by { |method| method["line"] }
		return if @changed.empty? && @summary.uncovered.empty? && never_called.empty?

		dl(class: "problems") do
			if @changed.any?
				dt { "Changed, not run" }
				dd { render Quickdraw::CoverageHTML::LineLinks.new(@changed) }
			end

			if @summary.uncovered.any?
				dt { "Not run" }
				dd { render Quickdraw::CoverageHTML::LineLinks.new(@summary.uncovered) }
			end

			if never_called.any?
				dt { "Never called" }
				dd do
					ul(class: "plain") do
						never_called.each do |method|
							li { a(href: "#L#{method['line']}") { code { method["name"] } } }
						end
					end
				end
			end
		end
	end

	private def source
		unless File.file?(@summary.path)
			p(class: "warning") { "#{@summary.path} no longer exists, so its source can't be shown." }
			return
		end

		lines = File.read(@summary.path, encoding: Encoding::UTF_8).scrub.lines(chomp: true)
		notes = untaken_branches
		changed = @changed.to_set

		if lines.size != @data["lines"].size
			p(class: "warning") { "#{@summary.path} has changed since tests loaded it, so counts may be on the wrong lines." }
		end

		div(class: "source") do
			table do
				tbody do
					lines.each.with_index(1) do |text, number|
						count = @data["lines"][number - 1]

						tr(id: "L#{number}", class: [state(count), ("changed" if changed.include?(number))]) do
							td(class: "number") { a(href: "#L#{number}") { number } }
							td(class: "hits") { count }
							td(class: "code") do
								plain text
								span(class: "note changed") { "changed, not run" } if changed.include?(number)
								notes[number]&.each { |note| span(class: "note") { note } }
							end
						end
					end
				end
			end
		end
	end

	private def state(count)
		case count
		in nil then nil
		in 0 then "uncovered"
		in Integer then "covered"
		end
	end

	# { line => notes } for the targets never taken of branches that ran, on
	# the targets' lines. A branch that never ran is already on a line not run.
	private def untaken_branches
		@data["branches"].each_with_object({}) do |branch, notes|
			next if branch["targets"].all? { |target| target["count"] == 0 }

			branch["targets"].each do |target|
				(notes[target["line"]] ||= []) << describe(branch["type"], target["type"]) if target["count"] == 0
			end
		end
	end

	private def describe(branch, target)
		case [branch, target]
		in ["&.", "then"] then "receiver always nil"
		in ["&.", "else"] then "receiver never nil"
		in [_, "body"] then "loop body never run"
		in [_, _] then "#{target} never taken"
		end
	end
end
