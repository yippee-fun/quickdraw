# frozen_string_literal: true

# A method that mutants change. `nesting` is the classes and modules around its
# definition, outermost first, as [keyword, name] such as ["class", "Admin::User"]
# or ["class", "<< self"]. `path` is absolute, and `id` is unique in a run.
Quickdraw::Mutation::Subject = Data.define(:id, :path, :line, :nesting, :name, :singleton) do
	# The class or module the method is defined on. Raises NameError if one of
	# those around it isn't defined, and TypeError if it isn't a module.
	def owner
		scopes = [Object]

		nesting.each do |keyword, name|
			scopes << case [keyword, name]
			in ["class", "<< self"] then scopes.last.singleton_class
			in [_, /\A::(?<absolute>.+)\z/] then Object.const_get($~[:absolute], false)
			# As in `class Admin::User`, where Admin is found from any scope around it.
			in [_, /\A(?<first>[^:]+)::(?<rest>.+)\z/] then lexical(scopes, $~[:first]).const_get($~[:rest], false)
			else scopes.last.const_get(name, false)
			end

			raise TypeError, "#{scopes.last.inspect} isn’t a class or module" unless Module === scopes.last
		end

		singleton ? scopes.last.singleton_class : scopes.last
	end

	# The method its definition at path:line defined, or nil if it isn't
	# defined, or another definition has replaced it.
	def defined_method
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

	# As a backtrace would name it, e.g. Admin::User#name or Admin::User.find.
	def label
		owners = nesting.filter_map { |_keyword, name| name.delete_prefix("::") unless name == "<< self" }
		separator = (singleton || (nesting.last in ["class", "<< self"])) ? "." : "#"
		Quickdraw.utf8(owners.empty? ? name.to_s : "#{owners.join('::')}#{separator}#{name}")
	end
end
