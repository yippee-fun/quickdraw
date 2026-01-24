# frozen_string_literal: true

class Quickdraw::RSpec::Spec < Quickdraw::BasicTest
	include Quickdraw::RSpec::Matchers

	class << self
		def describe(description, &block)
			Class.new(self) do
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
			let("subject", &)
			let(name, &) if name
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
	end

	def expect(subject)
		Quickdraw::RSpec::Expectation.new(subject, context: self)
	end
end
