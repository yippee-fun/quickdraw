# frozen_string_literal: true

require "ruby_lsp/addon"
require_relative "../../quickdraw/version"

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

			def version = ::Quickdraw::VERSION
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
				# Find the innermost class node that contains our position
				class_node = nodes.reverse_each.find { |it| Prism::ClassNode === it }
				return false unless class_node

				# Get all BlockNodes from our nesting - these are the blocks we're inside
				block_nodes = nodes.grep(Prism::BlockNode)
				return false if block_nodes.empty?

				# Search the class body for `test` calls and check if any of our blocks
				# is the block of a test call
				test_blocks = collect_test_blocks(class_node.body)

				block_nodes.any? do |block_node|
					test_blocks.any? { |test_block| test_block.equal?(block_node) }
				end
			end

			private def collect_test_blocks(node, result = [])
				case node
				in Prism::CallNode[receiver: nil, name: :test | :fuzz, block: Prism::BlockNode => block]
					result << block
				in Prism::CallNode[receiver: nil, name: :describe, block: Prism::BlockNode => block]
					collect_test_blocks(block.body, result)
				in Prism::StatementsNode
					node.body.each { |child| collect_test_blocks(child, result) }
				else nil
				end

				result
			end
		end
	end
end
