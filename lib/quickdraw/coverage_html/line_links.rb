# frozen_string_literal: true

# Line numbers as ranges, such as "3-5, 9", each linking to its first line on
# the page at `page`.
class Quickdraw::CoverageHTML::LineLinks < Phlex::HTML
	def initialize(numbers, page: "")
		@numbers = numbers
		@page = page
	end

	def view_template
		span(class: "lines") do
			@numbers.slice_when { |previous, number| number != previous + 1 }.each do |run|
				a(href: "#{@page}#L#{run.first}") { Quickdraw::CoverageReport.ranges(run) }
			end
		end
	end
end
