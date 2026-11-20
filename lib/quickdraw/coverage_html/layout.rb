# frozen_string_literal: true

class Quickdraw::CoverageHTML::Layout < Phlex::HTML
	STYLES = File.read(File.join(__dir__, "styles.css")).freeze

	def initialize(title:)
		@title = title
	end

	def view_template(&content)
		doctype

		html(lang: "en") do
			head do
				meta(charset: "utf-8")
				meta(name: "viewport", content: "width=device-width, initial-scale=1")
				title { @title }
				style { raw(safe(STYLES)) }
			end

			body { main(&content) }
		end
	end
end
