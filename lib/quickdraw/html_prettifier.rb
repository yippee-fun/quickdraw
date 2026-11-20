# frozen_string_literal: true

begin
	require "nokogiri"
rescue LoadError => error
	# Not if it's installed but couldn't load, which says why itself.
	raise unless error.path == "nokogiri"

	raise LoadError, "assert_equivalent_html needs nokogiri, to compare HTML, which isn’t installed. Add it to the Gemfile’s test group."
end

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

	# JRuby's Nokogiri has no HTML5 parser.
	PARSER = defined?(Nokogiri::HTML5) ? Nokogiri::HTML5 : Nokogiri::HTML4

	def prettify(html)
		node = case html
		when Nokogiri::HTML4::DocumentFragment
			html
		when String
			PARSER.fragment(html)
		else
			raise ArgumentError.new("Expected a Nokogiri HTML fragment or a String, but got a #{html.class}")
		end

		prettify_node(node)
	end

	def prettify_node(node, depth = 0)
		indent = "  " * depth

		case node
		when Nokogiri::HTML4::DocumentFragment
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
