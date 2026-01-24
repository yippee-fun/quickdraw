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
			private

			def handle_nesting_nodes(nodes)
				nesting, surrounding_method = super

				if @call_node.is_a?(Prism::CallNode) && @call_node.block
					case @call_node.name
					when :test
						# If we're inside a `test` block, treat it as an instance method context
						# so that `self` resolves to an instance of the test class
						surrounding_method ||= "<test>"
					when :Quickdraw
						# If we're inside a `Quickdraw` block, treat it as being inside `Quickdraw::Test`
						# so constants and methods resolve correctly
						nesting << "Quickdraw::Test"
					end
				end

				[nesting, surrounding_method]
			end
		end
	end
end
