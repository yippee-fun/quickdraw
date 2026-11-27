# frozen_string_literal: true

# A change to one method of `subject`: its whole definition as mutated, in
# `source`. The change spans `line` to `last_line`, shown as `before` and
# `after`. A test can only kill it if it runs `covering_line`, the line of the
# statement it's in.
Quickdraw::Mutation::Mutant = Data.define(:id, :subject, :line, :last_line, :covering_line, :description, :source, :frozen_string_literal, :before, :after) do
	# Defines the mutated method in place of the original, in a worker, within
	# the same classes and modules so constants resolve as they did. Keeps the
	# original's visibility, which a `private` before it set. Raises if the
	# original isn't there to replace.
	def apply
		owner = subject.owner
		original = subject.defined_method or raise NameError, "#{subject.label} isn’t defined at #{subject.path}:#{subject.line}"
		name = subject.name

		visibility = if owner.private_method_defined?(name, false) then :private
		elsif owner.protected_method_defined?(name, false) then :protected
		else :public
		end

		function = module_function?(owner, original)
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
		owner.__send__(visibility, name) unless visibility == :public
		owner.__send__(:module_function, name) if function
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
