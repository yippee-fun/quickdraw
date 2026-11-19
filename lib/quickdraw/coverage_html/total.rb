# frozen_string_literal: true

class Quickdraw::CoverageHTML::Total < Phlex::HTML
	def initialize(name, count)
		@name = name
		@count = count
	end

	def view_template
		div(class: "total") do
			h2 { @name }
			render Quickdraw::CoverageHTML::Percentage.new(@count)
			p(class: "muted") { "#{@count.covered} of #{@count.total} covered" }
		end
	end
end
