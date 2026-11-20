# frozen_string_literal: true

class RubyLspAddonTest < Quickdraw::Test
	def setup
		skip "Loading the addon without Ruby LSP needs fork" unless Process.respond_to?(:fork)
	end

	# Whether the addon takes `here` in `source` to be inside a test. In a fork,
	# with a stand-in for Ruby LSP, which isn't installed.
	def in_test?(source)
		Quickdraw.isolate do
			require "prism"
			Object.const_set(:RubyLsp, Module.new).const_set(:Addon, Class.new)
			$LOADED_FEATURES << "ruby_lsp/addon.rb"
			require_relative "../lib/ruby_lsp/quickdraw/addon"

			nodes = nesting(Prism.parse(source).value) or raise "There’s no `here` in the source."
			Object.new.extend(RubyLsp::Quickdraw::NodeContextPatch).__send__(:inside_test_block?, nodes)
		end
	end

	# The nodes around `here`, outermost first, as Ruby LSP gives them.
	def nesting(node, ancestors = [])
		case node
		in Prism::CallNode[name: :here] then ancestors
		else node.compact_child_nodes.lazy.filter_map { |child| nesting(child, [*ancestors, node]) }.first
		end
	end

	test "finds tests, in describe blocks too" do
		assert in_test?("class A < Quickdraw::Test\n\ttest('a') { here }\nend")
		assert in_test?("class A < Quickdraw::Test\n\tdescribe('a') { describe('b') { test('c') { here } } }\nend")
		refute in_test?("class A < Quickdraw::Test\n\tother('a') { here }\nend")
		refute in_test?("class A < Quickdraw::Test\n\tother.test('a') { here }\nend")
	end

	test "finds fuzz tests" do
		assert in_test?("class A < Quickdraw::Test\n\tfuzz('a') { here }\nend")
	end

	test "finds tests in a class inside another" do
		assert in_test?("class A < Quickdraw::Test\n\tclass B < Quickdraw::Test\n\t\ttest('a') { here }\n\tend\nend")
	end
end
