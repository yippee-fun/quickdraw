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
		wrapped = "#{subject.nesting.map { |keyword, scope| "#{keyword} #{scope}; " }.join}#{source}\n#{'end; ' * subject.nesting.size}"
		# On the definition's line, so backtraces and __LINE__ are as they were.
		first_line = subject.line

		if frozen_string_literal
			wrapped = "# frozen_string_literal: true\n#{wrapped}"
			first_line -= 1
		end

		# In the source's encoding, which an ASCII-only method loses when wrapped.
		TOPLEVEL_BINDING.eval(wrapped.force_encoding(source.encoding), subject.path, first_line)
		owner.__send__(visibility, name) unless visibility == :public
		owner.__send__(:module_function, name) if function
	end

	# Whether `module_function` copied the method to its module, which then
	# needs the mutant too.
	private def module_function?(owner, original)
		return false if Class === owner || !owner.singleton_class.method_defined?(subject.name, false)

		owner.singleton_class.instance_method(subject.name).source_location == original.source_location
	end
end
