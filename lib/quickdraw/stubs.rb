# frozen_string_literal: true

# Stubs and spies, undone after the test in reverse order. They change shared
# objects, constants and ENV, so other threads see them while the test runs.
# Tests only get these four methods, so a test's own helpers and constants
# aren't shadowed.
module Quickdraw::Stubs
	# Replaces the object's method with the block, or one that returns `returns`.
	def stub(object, name, returns: Quickdraw::Null, &block)
		if Quickdraw::Null.equal?(returns)
			raise ::ArgumentError, "stub needs a block or returns:." unless block
		else
			raise ::ArgumentError, "stub takes a block or returns:, not both." if block

			block = proc { returns }
		end

		Quickdraw::Stubs.validate(object, name)
		defer(&Quickdraw::Stubs.replace(object, name) { |*args, **kwargs, &given| block.call(*args, **kwargs, &given) })

		nil
	end

	# Records each call to the object's method, which still runs.
	def spy(object, name)
		Quickdraw::Stubs.validate(object, name)
		name = name.to_sym
		original = Quickdraw::Stubs.beneath(Quickdraw::Stubs.singleton_class_of(object), name)
		spy = Quickdraw::Spy.new

		defer(&Quickdraw::Stubs.replace(object, name) do |*args, **kwargs, &block|
			result = if original
				original.bind_call(self, *args, **kwargs, &block)
			else
				__send__(:method_missing, name, *args, **kwargs, &block)
			end
		rescue Exception => error
			raise
		ensure
			spy.record(Quickdraw::Spy::Call.new(args:, kwargs:, block:, result:, error:, thread: Quickdraw::Spy::CURRENT_THREAD.call))
		end)

		spy
	end

	# Sets a constant, such as "Billing::RATE", defining it if it's missing.
	def stub_const(path, value)
		raise ::ArgumentError, "stub_const needs a constant's path as a String, not #{path.inspect}." unless String === path

		*parents, name = names = path.delete_prefix("::").split("::", -1)
		raise ::ArgumentError, "#{path.inspect} isn't a constant's path." if names.empty? || names.any?(&:empty?)

		parent = parents.empty? ? Object : Object.const_get(parents.join("::"))
		raise ::ArgumentError, "#{parents.join('::')} isn't a class or module." unless Module === parent

		name = name.to_sym
		existed = parent.const_defined?(name, false)
		# Not loaded, so the stub can stand in for what loading would do.
		autoload = parent.autoload?(name, false)
		original = parent.const_get(name, false) if existed && !autoload
		hidden = existed && !parent.constants(false).include?(name)

		parent.__send__(:remove_const, name) if existed
		parent.const_set(name, value)
		parent.private_constant(name) if hidden

		defer do
			parent.__send__(:remove_const, name) if parent.const_defined?(name, false)

			if autoload
				parent.autoload(name, autoload)
			elsif existed
				parent.const_set(name, original)
			end

			parent.private_constant(name) if hidden
		end

		nil
	end

	# Sets ENV variables, deleting those set to nil.
	def stub_env(variables)
		raise ::ArgumentError, "stub_env needs a Hash, as in stub_env(\"KEY\" => \"value\")." unless Hash === variables

		variables.each do |key, value|
			raise ::ArgumentError, "ENV's keys are Strings, not #{key.inspect}." unless String === key
			raise ::ArgumentError, "ENV's values are Strings or nil, not #{value.inspect}." unless value in String | nil
		end

		originals = variables.to_h { |key, _| [key, ENV[key]] }
		defer { originals.each { |key, value| value ? ENV[key] = value : ENV.delete(key) } }
		variables.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }

		nil
	end

	def self.validate(object, name)
		raise ::ArgumentError, "A method's name is a Symbol or String, not #{name.inspect}." unless name in Symbol | String
		raise ::ArgumentError, "Can't replace #{name}: #{described(object)} is frozen." if object.frozen?
		raise ::ArgumentError, "Can't replace #{name}: #{described(object)} has no such method." unless object.respond_to?(name, true)
	end

	# Without calling the object's own singleton_class, which it could override.
	def self.singleton_class_of(object) = class << object; self; end

	# The method a call reaches after any modules prepended to the singleton
	# class, such as Leaks' wrapper of Thread.new, or nil for method_missing.
	def self.beneath(singleton, name)
		return unless singleton.method_defined?(name) || singleton.private_method_defined?(name)

		prepended = singleton.ancestors.take_while { |it| !it.equal?(singleton) }
		method = singleton.instance_method(name)
		method = method.super_method while method && prepended.any? { |it| it.equal?(method.owner) }
		method
	end

	# Defines the method on the object's singleton class, beneath any modules
	# prepended to it, with the visibility it had, and returns what undoes that.
	# Undone, the singleton class is as it was, so the object can be marshaled again.
	def self.replace(object, name, &body)
		name = name.to_sym
		singleton = singleton_class_of(object)

		visibility = if singleton.private_method_defined?(name)
			:private
		elsif singleton.protected_method_defined?(name)
			:protected
		else
			:public
		end

		previous = own(singleton, name)
		singleton.define_method(name, &body)
		singleton.__send__(visibility, name)

		lambda do
			if previous
				singleton.define_method(name, previous)
				singleton.__send__(visibility, name)
			elsif own(singleton, name)
				singleton.remove_method(name)
			end
		end
	end

	private_class_method def self.own(singleton, name)
		method = beneath(singleton, name)
		method if method&.owner.equal?(singleton)
	end

	private_class_method def self.described(object) = (Module === object) ? object.inspect : "an instance of #{object.class}"
end
