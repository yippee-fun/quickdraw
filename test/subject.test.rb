# frozen_string_literal: true

class SubjectTest < Quickdraw::Test
	def setup
		super
		skip "mutate reads CRuby's instruction sequences, and needs fork anyway" unless defined?(RubyVM::InstructionSequence)
	end

	def subjects(path, source)
		Quickdraw::Mutation::Mutator.new(path, source).call.map(&:subject).uniq(&:id).select(&:block)
	end

	test "finds the blocks a DSL keeps, loading their classes if they're autoloaded, but not the blocks in them" do
		path = File.join(tmpdir, "visitor.rb")
		name = "SubjectTestVisitor#{Process.pid}"

		source = <<~RUBY
			class #{name}
				def self.visit(type, &) = define_method("visit_\#{type}", &)
				def self.convert(type, &block) = define_method("convert_\#{type}") { |value| instance_exec(value, &block) }
				def self.once(&) = yield

				visit :list do |values| values.map { |value| value * 2 } end

				convert :text do |value|
					value.upcase
				end

				once do
					1 + 1
				end
			end
		RUBY

		File.write(path, source)
		Object.autoload(name, path)
		visit, convert, once = subjects(path, source)

		blocks = Quickdraw::Mutation::Subject.blocks([visit, convert, once])

		# Not `once`'s, which nothing keeps.
		assert_equal blocks.transform_values { |iseqs| iseqs.map(&:first_lineno) }, { visit.id => [6], convert.id => [8] }
	ensure
		Object.__send__(:remove_const, name) if Object.const_defined?(name, false)
	end
end
