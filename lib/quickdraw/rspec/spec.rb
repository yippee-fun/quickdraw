# frozen_string_literal: true

class Quickdraw::RSpec::Spec < Quickdraw::BasicTest
	include Quickdraw::RSpec::Matchers

	class << self
		def described_class
			@described_class || (superclass.described_class if superclass.respond_to?(:described_class))
		end

		def describe(*descriptions, &block)
			Class.new(self) do
				@described_class = descriptions.find { |m| Module === m }

				if respond_to?(:set_temporary_name)
					name_parts = descriptions.map do |desc|
						case desc
						when Class
							desc.name
						else
							desc.to_s
						end
					end
					set_temporary_name "(#{name_parts.join(' ')})"
				end
				class_exec(&block)
			end
		end

		alias_method :context, :describe

		def it(description, &)
			test(description, &)
		end

		def subject(name = nil, &)
			let(:subject, &)
			let(name, &) if name
		end

		def subject!(name = nil, &)
			let!(:subject, &)
			let!(name, &) if name
		end

		def let(name, &block)
			instance_variable = :"@#{name}"

			define_method(name) do
				if instance_variable_defined?(instance_variable)
					instance_variable_get(instance_variable)
				else
					instance_variable_set(instance_variable, instance_exec(&block))
				end
			end
		end

		def let!(name, &)
			let(name, &)
			own_eager_lets << name
		end

		def eager_lets
			parent = superclass.respond_to?(:eager_lets) ? superclass.eager_lets : []
			parent + own_eager_lets
		end

		def own_eager_lets
			@eager_lets ||= []
		end

		# Hooks

		def before(scope = :each, &block)
			case scope
			when :each
				own_before_each_hooks << block
			when :all, :context
				own_before_all_hooks << block
			else
				raise ArgumentError, "Invalid hook scope: #{scope.inspect}. Use :each, :all, or :context."
			end
		end

		def after(scope = :each, &block)
			case scope
			when :each
				own_after_each_hooks << block
			when :all, :context
				own_after_all_hooks << block
			else
				raise ArgumentError, "Invalid hook scope: #{scope.inspect}. Use :each, :all, or :context."
			end
		end

		def around(scope = :each, &block)
			unless scope == :each
				raise ArgumentError, "around hooks only support :each scope"
			end
			own_around_hooks << block
		end

		def before_each_hooks
			parent = superclass.respond_to?(:before_each_hooks) ? superclass.before_each_hooks : []
			parent + own_before_each_hooks
		end

		def after_each_hooks
			parent = superclass.respond_to?(:after_each_hooks) ? superclass.after_each_hooks : []
			own_after_each_hooks + parent # after hooks run in reverse order
		end

		def around_hooks
			parent = superclass.respond_to?(:around_hooks) ? superclass.around_hooks : []
			parent + own_around_hooks
		end

		def before_all_hooks
			parent = superclass.respond_to?(:before_all_hooks) ? superclass.before_all_hooks : []
			parent + own_before_all_hooks
		end

		def after_all_hooks
			parent = superclass.respond_to?(:after_all_hooks) ? superclass.after_all_hooks : []
			own_after_all_hooks + parent # after hooks run in reverse order
		end

		def own_before_each_hooks
			@before_each_hooks ||= []
		end

		def own_after_each_hooks
			@after_each_hooks ||= []
		end

		def own_around_hooks
			@around_hooks ||= []
		end

		def own_before_all_hooks
			@before_all_hooks ||= []
		end

		def own_after_all_hooks
			@after_all_hooks ||= []
		end

		def run_before_all_hooks_once
			@before_all_mutex ||= Mutex.new
			@before_all_mutex.synchronize do
				return if @before_all_ran
				@before_all_ran = true
				@before_all_state = {}
				before_all_hooks.each do |hook|
					# Create a temporary instance to run the hook and capture instance variables
					instance = allocate
					instance.instance_variable_set(:@__before_all_state, @before_all_state)
					@before_all_state.each { |k, v| instance.instance_variable_set(k, v) }
					instance.instance_exec(&hook)
					# Capture any instance variables set during the hook
					instance.instance_variables.each do |ivar|
						next if ivar == :@__before_all_state
						@before_all_state[ivar] = instance.instance_variable_get(ivar)
					end
				end
			end
		end

		def run_after_all_hooks_once
			@after_all_mutex ||= Mutex.new
			@after_all_mutex.synchronize do
				return if @after_all_ran
				@after_all_ran = true
				after_all_hooks.each do |hook|
					instance = allocate
					(@before_all_state || {}).each { |k, v| instance.instance_variable_set(k, v) }
					instance.instance_exec(&hook)
				end
			end
		end

		def before_all_state
			@before_all_state || {}
		end

		# Shared examples

		def shared_examples(name, metadata = nil, &block)
			own_shared_examples[name] = { block:, metadata: }
		end

		def it_behaves_like(name, *args, &customization_block)
			shared = find_shared_examples(name)
			raise ArgumentError, "Shared examples '#{name}' not found" unless shared

			# Create a nested context for it_behaves_like to avoid method override issues
			describe "behaves like #{name}" do
				class_exec(*args, &shared[:block])
				class_exec(&customization_block) if customization_block
			end
		end

		def it_should_behave_like(name, *args, &customization_block)
			it_behaves_like(name, *args, &customization_block)
		end

		def include_examples(name, *args, &customization_block)
			shared = find_shared_examples(name)
			raise ArgumentError, "Shared examples '#{name}' not found" unless shared

			# include_examples runs in the current context (no nesting)
			class_exec(*args, &shared[:block])
			class_exec(&customization_block) if customization_block
		end

		def alias_it_should_behave_like_to(new_name, description_prefix = nil)
			if description_prefix
				define_singleton_method(new_name) do |name, *args, &customization_block|
					shared = find_shared_examples(name)
					raise ArgumentError, "Shared examples '#{name}' not found" unless shared

					describe "#{description_prefix} #{name}" do
						class_exec(*args, &shared[:block])
						class_exec(&customization_block) if customization_block
					end
				end
			else
				define_singleton_method(new_name) do |name, *args, &customization_block|
					it_behaves_like(name, *args, &customization_block)
				end
			end
		end

		def find_shared_examples(name)
			own_shared_examples[name] ||
				(superclass.find_shared_examples(name) if superclass.respond_to?(:find_shared_examples)) ||
				Quickdraw::RSpec.global_shared_examples[name]
		end

		def own_shared_examples
			@shared_examples ||= {}
		end
	end

	def described_class
		self.class.described_class
	end

	def setup
		super
		# Run before(:all) hooks once per class
		self.class.run_before_all_hooks_once
		# Copy state from before(:all) hooks
		self.class.before_all_state.each { |k, v| instance_variable_set(k, v) }
		# Run before(:each) hooks
		self.class.before_each_hooks.each { |hook| instance_exec(&hook) }
		# Run eager lets
		self.class.eager_lets.each { |name| __send__(name) }
	end

	def teardown
		# Run after(:each) hooks
		self.class.after_each_hooks.each { |hook| instance_exec(&hook) }
		super
	end

	def around_test
		hooks = self.class.around_hooks

		if hooks.empty?
			yield
		else
			# Build a chain of around hooks
			chain = hooks.reverse.reduce(-> { yield }) do |inner, hook|
				-> { instance_exec(inner, &hook) }
			end
			chain.call
		end
	end

	def expect(subject)
		Quickdraw::RSpec::Expectation.new(subject, context: self)
	end
end
