# frozen_string_literal: true

class Quickdraw::RSpec::Spec < Quickdraw::BasicTest
	include Quickdraw::RSpec::Matchers

	class << self
		def described_class
			@described_class || (superclass.described_class if superclass.respond_to?(:described_class))
		end

		def describe(description, &block)
			Class.new(self) do
				case description
				when Class, Module
					@described_class = description
				end

				if respond_to?(:set_temporary_name)
					case description
					when Class
						set_temporary_name "(#{description.name})"
					else
						set_temporary_name "(#{description})"
					end
				end
				class_exec(&block)
			end
		end

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
		self.class.eager_lets.each { |name| send(name) }
	end

	def expect(subject)
		Quickdraw::RSpec::Expectation.new(subject, context: self)
	end
end
