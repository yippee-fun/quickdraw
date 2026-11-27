# frozen_string_literal: true

# A change to one method or block of `subject`: its whole definition as
# mutated, or for a block, the whole call it's given to, in `source`. The
# change spans `line` to `last_line`, shown as `before` and `after`. A test
# can only kill it if it runs `covering_line`, the line of the statement it's
# in.
Quickdraw::Mutation::Mutant = Data.define(:id, :subject, :line, :last_line, :covering_line, :description, :source, :frozen_string_literal, :before, :after) do
	# Defines the mutated method in place of the original, in a worker, within
	# the same classes and modules so constants resolve as they did. Keeps the
	# original's visibility, which a `private` before it set. Raises if the
	# original isn't there to replace. For a block, see #apply_block.
	def apply
		return apply_block if subject.block

		owner = subject.owner
		original = subject.defined_method or raise NameError, "#{subject.label} isn’t defined at #{subject.path}:#{subject.line}"
		name = subject.name

		visibility = if owner.private_method_defined?(name, false) then :private
		elsif owner.protected_method_defined?(name, false) then :protected
		else :public
		end

		function = module_function?(owner, original)
		evaluate
		owner.__send__(visibility, name) unless visibility == :public
		owner.__send__(:module_function, name) if function
		nil
	end

	# Makes the block's call again, mutated, in place of the original: what
	# it's given to, such as a DSL's `define_method`, then replaces what the
	# original block did. But one that keeps every block it's given, as
	# callbacks do, keeps the original too, so this watches whether that one
	# still runs, which would mean the mutant can't survive or die on its own.
	# Returns a lambda that says whether it has run since.
	private def apply_block
		# Raises if the classes around it aren't there, rather than making them.
		subject.owner
		originals = Quickdraw::Mutation::Subject.blocks([subject]).fetch(subject.id) do
			raise NameError, "#{subject.label} at #{subject.path}:#{subject.line} isn’t kept once its call returns"
		end

		evaluate
		ran = false
		originals.each do |original|
			TracePoint.new(:line, :b_call) { ran = true }.enable(target: original)
		rescue ArgumentError
			nil
		end

		-> { ran }
	end

	# Evaluates `source` within the classes and modules around it.
	private def evaluate
		opening = subject.nesting.map.with_index(1) do |(keyword, scope), depth|
			case keyword
			in "class_eval" then "#{scope}.class_eval do; #{usings(depth)}"
			in "class" | "module" then "#{keyword} #{scope}; #{usings(depth)}"
			end
		end

		wrapped = "#{usings(0)}#{opening.join}#{source}\n#{'end; ' * subject.nesting.size}"
		# On the definition's line, so backtraces and __LINE__ are as they were.
		first_line = subject.line

		if frozen_string_literal
			wrapped = "# frozen_string_literal: true\n#{wrapped}"
			first_line -= 1
		end

		# In the source's encoding, which an ASCII-only method loses when wrapped.
		# As a file of its own, so its refinements don't reach code the tests
		# evaluate at the top level.
		RubyVM::InstructionSequence.compile(wrapped.force_encoding(source.encoding), subject.path, subject.path, first_line).eval
	end

	# The original's refinements activated at `depth` of its nesting, as they
	# were, since a refinement only applies in the code after its `using`.
	private def usings(depth)
		subject.usings.filter_map { |at, refinement| "using #{refinement}; " if at == depth }.join
	end

	# Whether `module_function` copied the method to its module, which then
	# needs the mutant too.
	private def module_function?(owner, original)
		return false if Class === owner || !owner.singleton_class.method_defined?(subject.name, false)

		owner.singleton_class.instance_method(subject.name).source_location == original.source_location
	end
end
