# frozen_string_literal: true

# A CoverageReport::Count as a bar and a percentage, coloured by how much is
# covered. Rounded down, so 99.9% isn't shown as 100%.
class Quickdraw::CoverageHTML::Percentage < Phlex::HTML
	def initialize(count)
		@count = count
	end

	def view_template
		if @count.total == 0
			span(class: "percentage none", title: "Nothing to cover") { span(class: "value") { "—" } }
			return
		end

		percent = @count.covered * 100 / @count.total

		span(class: ["percentage", level], title: "#{@count.covered} of #{@count.total}") do
			span(class: "bar") { span(style: { width: "#{percent}%" }) }
			span(class: "value") { "#{percent}%" }
		end
	end

	private def level
		case @count.ratio
		in 0.9.. then "high"
		in 0.7.. then "medium"
		else "low"
		end
	end
end
