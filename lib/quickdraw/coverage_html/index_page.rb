# frozen_string_literal: true

class Quickdraw::CoverageHTML::IndexPage < Phlex::HTML
	def initialize(report)
		@report = report
	end

	def view_template
		render Quickdraw::CoverageHTML::Layout.new(title: "Coverage") do
			h1 { "Coverage" }

			section(class: "totals") do
				render Quickdraw::CoverageHTML::Total.new("Lines", @report.lines)
				render Quickdraw::CoverageHTML::Total.new("Branches", @report.branches)
				render Quickdraw::CoverageHTML::Total.new("Methods", @report.methods)
			end

			changed_lines if @report.changed
			never_loaded if @report.never_loaded.any?
			file_table
		end
	end

	private def changed_lines
		count, uncovered = @report.changed
		pages = @report.files.to_set(&:path)

		section(id: "changed") do
			h2 { "Changed lines" }
			p do
				render Quickdraw::CoverageHTML::Percentage.new(count)
				span(class: "muted") { " #{count.covered} of #{count.total} lines changed since the last commit were run" }
			end

			if uncovered.any?
				ul(class: "plain") do
					uncovered.each do |path, numbers|
						li do
							if pages.include?(path)
								a(href: Quickdraw::CoverageHTML.href(path)) { code { path } }
								plain " "
								render Quickdraw::CoverageHTML::LineLinks.new(numbers, page: Quickdraw::CoverageHTML.href(path))
							else
								code { path }
								span(class: "muted") { " never loaded by a test" }
							end
						end
					end
				end
			end
		end
	end

	private def never_loaded
		section(id: "never-loaded") do
			h2 { "Never loaded by a test" }
			p(class: "muted") { "No test loaded these files, so they aren't in the totals." }

			ul(class: "plain") do
				@report.never_loaded.each { |path| li { code { path } } }
			end
		end
	end

	private def file_table
		section(id: "files") do
			h2 { "Files" }

			div(class: "scroll") do
				table(class: "files") do
					thead do
						tr do
							th { "File" }
							th { "Lines" }
							th { "Branches" }
							th { "Methods" }
							th { "Not run" }
						end
					end

					tbody do
						@report.files.sort_by { |file| [file.lines.ratio, -file.uncovered.size, file.path] }.each do |file|
							tr do
								td { a(href: Quickdraw::CoverageHTML.href(file.path)) { code { file.path } } }
								td { render Quickdraw::CoverageHTML::Percentage.new(file.lines) }
								td { render Quickdraw::CoverageHTML::Percentage.new(file.branches) }
								td { render Quickdraw::CoverageHTML::Percentage.new(file.methods) }
								td(class: ("muted" if file.uncovered.empty?)) { file.uncovered.size }
							end
						end
					end
				end
			end
		end
	end
end
