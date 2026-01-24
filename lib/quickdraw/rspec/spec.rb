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
