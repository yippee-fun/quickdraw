# frozen_string_literal: true

# A method that mutants change, or a block given to a call directly in a class
# or module's body, as in `visit Node do |node| … end`. `nesting` is the
# classes and modules around its definition, outermost first, as [keyword,
# name] such as ["class", "Admin::User"] or ["class", "<< self"], or
# ["class_eval", "Point"] for a block evaluated in a class, as in
# `Point = Data.define do`. `usings` are the refinements its
# file activates before it, as [depth, constant], where depth is how many of
# `nesting` are around the `using`. `path` is absolute, and `id` is unique in
# a run. A block's `name` is the call it's given to, as written, such as
# "visit Node", and `block` is where it opens (its `do` or `{`), as [line,
# column]; a method's `block` is nil.
Quickdraw::Mutation::Subject = Data.define(:id, :path, :line, :nesting, :usings, :name, :singleton, :block) do
	# { subject id => the instruction sequences of their blocks } for those of
	# `subjects` that are blocks something still holds once their calls have
	# returned: a method `define_method` made from one, or a Proc kept to call.
	# Some Rubies give a block's Procs copies of it, so it can have more than
	# one. With one pass over the heap for all of them.
	def self.blocks(subjects)
		wanted = subjects.select do |subject|
			next false unless subject.block

			# Which loads it, if it's autoloaded, and so makes the call.
			subject.owner
		rescue NameError, TypeError
			false
		end

		wanted = wanted.group_by { |subject| subject.block.first }
		return {} if wanted.empty?

		realpaths = Hash.new do |hash, path|
			hash[path] = begin
				File.realpath(path)
			rescue SystemCallError
				nil
			end
		end
		found = {}

		ObjectSpace.each_object(Proc) do |block|
			path, line = block.source_location
			candidates = (wanted[line] if path) or next
			candidates = candidates.select { |subject| realpaths[path] && realpaths[path] == realpaths[subject.path] }
			next if candidates.empty?

			# Where it opens, as a block inside it can open on the same line.
			iseq = RubyVM::InstructionSequence.of(block)
			opening = iseq.to_a[4][:code_location].first(2)
			candidates.each { |subject| (found[subject.id] ||= []) << iseq if opening == subject.block }
		end

		found.transform_values { |iseqs| iseqs.uniq(&:__id__) }
	end

	# The class or module the method is defined on. Raises NameError if one of
	# those around it isn't defined, and TypeError if it isn't a module.
	def owner
		scopes = [Object]
		# Not a block's class, which doesn't change where constants are found.
		lexical_scopes = [Object]

		nesting.each do |keyword, name|
			scopes << case [keyword, name]
			in ["class", "<< self"] then scopes.last.singleton_class
			in [_, /\A::(?<absolute>.+)\z/] then Object.const_get($~[:absolute], false)
			# As in `class Admin::User`, where Admin is found from any scope around it.
			in [_, /\A(?<first>[^:]+)::(?<rest>.+)\z/] then lexical(lexical_scopes, $~[:first]).const_get($~[:rest], false)
			else scopes.last.const_get(name, false)
			end

			raise TypeError, "#{scopes.last.inspect} isn’t a class or module" unless Module === scopes.last

			lexical_scopes << scopes.last unless keyword == "class_eval"
		end

		singleton ? scopes.last.singleton_class : scopes.last
	end

	# The method its definition at path:line defined, or nil if it isn't
	# defined, or another definition has replaced it.
	def defined_method
		return if block

		method = owner.instance_method(name)
		location_path, location_line = method.source_location
		method if location_line == line && location_path && File.realpath(location_path) == File.realpath(path)
	rescue NameError, TypeError, SystemCallError
		nil
	end

	# As Ruby finds it: in the scopes around it, innermost first, then in the
	# innermost one's ancestors, then in Object.
	private def lexical(scopes, name)
		scope = scopes.drop(1).reverse_each.find { |it| it.const_defined?(name, false) }
		scope ? scope.const_get(name, false) : scopes.last.const_get(name)
	end

	# As a backtrace would name it, e.g. Admin::User#name or Admin::User.find,
	# or for a block, Admin::User with its call, as Admin::User visit Node do.
	def label
		owners = nesting.filter_map { |_keyword, name| name.delete_prefix("::") unless name == "<< self" }
		return Quickdraw.utf8([*(owners.join("::") if owners.any?), name, "do"].join(" ")) if block
		separator = (singleton || (nesting.last in ["class", "<< self"])) ? "." : "#"
		Quickdraw.utf8(owners.empty? ? name.to_s : "#{owners.join('::')}#{separator}#{name}")
	end
end
