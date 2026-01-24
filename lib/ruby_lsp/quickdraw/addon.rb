# frozen_string_literal: true

require "ruby_lsp/addon"

module RubyLsp
	module Quickdraw
		class Addon < ::RubyLsp::Addon
			def activate(global_state, outgoing_queue)
				::RubyLsp::NodeContext.prepend(NodeContextPatch)
			end

			def deactivate; end

			def name
				"Quickdraw"
			end

			def version
				"0.1.0"
			end
		end

		module NodeContextPatch
			private def handle_nesting_nodes(nodes)
				nesting, surrounding_method = super

				# If we're not already inside a method, check if we're inside a `test` block
				if surrounding_method.nil? && inside_test_block?(nodes)
					# Use a synthetic method name to make Ruby LSP treat `self` as an instance
					surrounding_method = "<test>"
				end

				[nesting, surrounding_method]
			end

			private def inside_test_block?(nodes)
				# Find the class node that contains our position
				class_node = nodes.find { |n| n.is_a?(Prism::ClassNode) }
				return false unless class_node

				# Get all BlockNodes from our nesting - these are the blocks we're inside
				block_nodes = nodes.select { |n| n.is_a?(Prism::BlockNode) }
				return false if block_nodes.empty?

				# Search the class body for `test` calls and check if any of our blocks
				# is the block of a test call
				test_blocks = collect_test_blocks(class_node.body)

				block_nodes.any? do |block_node|
					test_blocks.any? { |test_block| test_block.equal?(block_node) }
				end
			end

			private def collect_test_blocks(node, result = [])
				return result unless node

				case node
				when Prism::CallNode
					if node.name == :test && node.block.is_a?(Prism::BlockNode)
						result << node.block
					end
				when Prism::StatementsNode
					node.body.each { |child| collect_test_blocks(child, result) }
				end

				result
			end
		end
	end
end
