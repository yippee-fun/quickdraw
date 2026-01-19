# frozen_string_literal: true

require "nokogiri"

module Quickdraw::HTMLPrettifier
	extend self

	VOID_ELEMENTS = Set[
		"area",
		"base",
		"br",
		"col",
		"embed",
		"hr",
		"img",
		"input",
		"link",
		"meta",
		"source",
		"track",
	].freeze

	def prettify(html)
		node = case html
		when Nokogiri::HTML5::DocumentFragment
			html
		when String
			Nokogiri::HTML5.fragment(html)
		else
			raise ArgumentError.new("Expected a Nokogiri::HTML5::DocumentFragment or a String, but got a #{html.class}")
		end

		prettify_node(node)
	end

	def prettify_node(node, depth = 0)
		indent = "  " * depth

		case node
		when Nokogiri::HTML5::DocumentFragment
			map_children(node, depth)
		when Nokogiri::XML::Element
			attributes = node.attribute_nodes.sort_by(&:name).map { |attr| prettify_node(attr) }.join
			opening_tag = "#{indent}<#{node.name}#{attributes}>"

			if VOID_ELEMENTS.include?(node.name)
				opening_tag
			else
				[
					opening_tag,
					map_children(node, depth + 1),
					"#{indent}</#{node.name}>",
				].freeze.compact.join("\n")
			end
		when Nokogiri::XML::Text
			text = node.text.strip
			"#{indent}#{text}" if text.length > 0
		when Nokogiri::XML::Attr
			if node.value == ""
				" #{node.name}"
			else
				%( #{node.name}="#{node.value}")
			end
		else
			raise ArgumentError.new("Unexpected node type: #{node.class}")
		end
	end

	def map_children(node, depth)
		if node.children.any?
			node.children.map { |child| prettify_node(child, depth) }.compact.join("\n")
		end
	end
end
