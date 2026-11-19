# frozen_string_literal: true

require "prism"

# Finds the mutants of a source file: changes to the code in its methods that
# a test running that code should notice. Only methods defined directly in
# classes, modules and `class << self`, which a worker can redefine.
#
# Mutations that can't change behaviour (x + 0 to x - 0) or that only break
# code any test running it would notice anyway (removing a local variable's
# assignment) are skipped, as are duplicates within a method.
class Quickdraw::Mutation::Mutator
	COMPARISONS = { :== => "!=", :!= => "==", :< => "<=", :<= => "<", :> => ">=", :>= => ">" }.freeze
	ARITHMETIC = { :+ => "-", :- => "+", :* => "/", :/ => "*", :% => "*", :** => "*" }.freeze
	# The argument for which the operator and its replacement agree.
	IDENTITIES = { :+ => 0, :- => 0, :* => 1, :/ => 1, :** => 1 }.freeze
	LOGICAL = { "&&" => "||", "||" => "&&", "and" => "or", "or" => "and" }.freeze

	METHODS = {
		select: "reject",
		filter: "reject",
		reject: "select",
		any?: "none?",
		none?: "any?",
		first: "last",
		last: "first",
		min: "max",
		max: "min",
		positive?: "negative?",
		negative?: "positive?",
		ceil: "floor",
		floor: "ceil",
		succ: "pred",
		pred: "succ",
		upcase: "downcase",
		downcase: "upcase",
	}.freeze

	def initialize(path, source, relative_path: path)
		@path = path
		@source = source
		@relative_path = relative_path
	end

	# The mutants that change any of `lines`, or all of them if nil. Raises
	# SyntaxError if the file doesn't parse.
	def call(lines: nil)
		result = Prism.parse(@source, filepath: @path)
		raise SyntaxError, result.errors.first.message if result.failure?

		@line_starts = result.source.offsets
		@frozen_string_literal = result.magic_comments.any? do |comment|
			comment.key.tr("-", "_").casecmp?("frozen_string_literal") && comment.value.casecmp?("true")
		end
		@mutants = []
		scope(result.value.statements, [])

		lines ? @mutants.select { |mutant| lines.any? { |line| line.between?(mutant.line, mutant.last_line) } } : @mutants
	end

	private def scope(body, nesting)
		return unless Prism::StatementsNode === body

		body.body.each do |node|
			case node
			in Prism::ClassNode then scope(node.body, [*nesting, ["class", node.constant_path.slice]])
			in Prism::ModuleNode then scope(node.body, [*nesting, ["module", node.constant_path.slice]])
			in Prism::SingletonClassNode[expression: Prism::SelfNode] then scope(node.body, [*nesting, ["class", "<< self"]])
			in Prism::DefNode then definition(node, nesting)
			in Prism::CallNode[
				receiver: nil,
				name: :private | :protected | :public | :module_function | :private_class_method | :public_class_method,
				arguments: Prism::ArgumentsNode[arguments: [Prism::DefNode => method]],
				block: nil,
			]
				definition(method, nesting)
			else nil
			end
		end
	end

	private def definition(node, nesting)
		singleton = case node.receiver
		in nil then false
		in Prism::SelfNode then true
		else return
		end

		return unless node.body

		line = node.location.start_line
		@method = node
		@locals = locals(node)
		@local_calls = local_calls(node)
		# With the column, since two methods can share a line.
		id = "#{@relative_path}:#{line}:#{node.location.start_column}"
		@subject = Quickdraw::Mutation::Subject.new(id:, path: @path, line:, nesting:, name: node.name, singleton:)
		@seen = {}
		replace_body(node.body)
		visit(node.body, line)
	end

	# `statement_line` is the line of the innermost statement around `node`.
	private def visit(node, statement_line)
		case node
		in Prism::StatementsNode
			node.body.each_with_index do |statement, index|
				remove(statement) if index < node.body.size - 1
				visit(statement, statement.location.start_line)
			end

			return
		in Prism::DefNode | Prism::ClassNode | Prism::ModuleNode | Prism::SingletonClassNode
			return
		in Prism::CallNode[name: :! | :not, receiver: Prism::Node => receiver, arguments: nil]
			add(node.location, receiver.slice, "removed the negation", statement_line)
		in Prism::CallNode[receiver: Prism::Node => receiver, arguments: Prism::ArgumentsNode[arguments: [argument]], message_loc: Prism::Location => message]
			operator(node, receiver, argument, message, statement_line)
		in Prism::CallNode[receiver: Prism::Node, message_loc: Prism::Location => message] if (replacement = METHODS[node.name])
			add(message, replacement, "#{node.name} → #{replacement}", statement_line)
		in Prism::AndNode | Prism::OrNode
			replacement = LOGICAL.fetch(node.operator)
			add(node.operator_loc, replacement, "#{node.operator} → #{replacement}", statement_line)
		in Prism::IfNode | Prism::UnlessNode
			negate(node.predicate, statement_line)
		in Prism::TrueNode
			add(node.location, "false", "true → false", statement_line)
		in Prism::FalseNode
			add(node.location, "true", "false → true", statement_line)
		in Prism::IntegerNode
			[node.value + 1, (0 unless node.value == 0)].compact.each do |value|
				add(node.location, value.to_s, "#{node.slice} → #{value}", statement_line)
			end
		else nil
		end

		node.compact_child_nodes.each { |child| visit(child, statement_line) }
	end

	private def operator(node, receiver, argument, message, statement_line)
		if (replacement = COMPARISONS[node.name])
			add(message, replacement, "#{node.name} → #{replacement}", statement_line)
		elsif (replacement = ARITHMETIC[node.name])
			# Concatenating or repeating strings and arrays, where the other operator raises.
			return if [receiver, argument].any? { |side| side in Prism::StringNode | Prism::InterpolatedStringNode | Prism::ArrayNode }
			return if (argument in Prism::IntegerNode) && argument.value == IDENTITIES[node.name]

			add(message, replacement, "#{node.name} → #{replacement}", statement_line)
		elsif (replacement = METHODS[node.name])
			add(message, replacement, "#{node.name} → #{replacement}", statement_line)
		end
	end

	# Not when the condition is already negated, since removing that negation does the same.
	private def negate(predicate, statement_line)
		return if predicate in Prism::CallNode[name: :! | :not]

		add(predicate.location, "!(#{predicate.slice})", "negated the condition", statement_line)
	end

	private def remove(statement)
		case statement
		in Prism::LocalVariableWriteNode | Prism::LocalVariableOperatorWriteNode | Prism::LocalVariableOrWriteNode | Prism::LocalVariableAndWriteNode | Prism::MultiWriteNode
			nil
		in Prism::NilNode | Prism::TrueNode | Prism::FalseNode | Prism::IntegerNode | Prism::StringNode | Prism::SymbolNode
			nil
		else
			add(statement.location, "nil", "removed the statement", statement.location.start_line)
		end
	end

	private def replace_body(body)
		statements = (Prism::BeginNode === body) ? body.statements : body
		return unless Prism::StatementsNode === statements
		return if statements.body in [Prism::NilNode]

		# Any test that calls the method, whose call event is on the definition's
		# line, since its first statement's line may have no line event.
		add(statements.location, "nil", "replaced the body with nil", @method.location.start_line)
	end

	private def add(location, replacement, description, covering_line)
		return if location.slice == replacement

		# With the lines it replaces, so the code after it keeps its line numbers.
		padding = "\n" * [location.slice.count("\n") - replacement.count("\n"), 0].max
		source = replace(location, "#{replacement}#{padding}", within: @method.location.start_offset, to: @method.location.end_offset)
		return if @seen.key?(source)

		@seen[source] = true
		result = Prism.parse(source)
		# Such as an endless method whose heredoc's body is after its end, or
		# removing a local variable's only assignment, which only breaks the
		# code that reads it.
		return if result.failure? || reads_removed_local?(result.value)

		line = location.start_line
		last_line = location.end_line
		line_start = @line_starts.fetch(line - 1)
		line_end = (@line_starts[last_line] || @source.bytesize)

		@mutants << Quickdraw::Mutation::Mutant.new(
			id: nil,
			subject: @subject,
			line:,
			last_line:,
			covering_line:,
			description:,
			source:,
			frozen_string_literal: @frozen_string_literal,
			before: @source.byteslice(line_start, line_end - line_start).chomp,
			after: replace(location, replacement, within: line_start, to: line_end).chomp,
		)
	end

	# The names of the local variables in a method and its blocks.
	private def locals(node)
		names = []
		names.concat(node.locals) if node in Prism::DefNode | Prism::BlockNode | Prism::LambdaNode
		node.compact_child_nodes.each { |child| names.concat(locals(child)) }
		names.uniq
	end

	# Whether more names that are local variables are read as method calls
	# than before, since every assignment before them was removed.
	private def reads_removed_local?(node)
		local_calls(node) > @local_calls
	end

	private def local_calls(node)
		own = ((node in Prism::CallNode) && node.variable_call? && @locals.include?(node.name)) ? 1 : 0
		node.compact_child_nodes.sum(own) { |child| local_calls(child) }
	end

	# The source from byte `within` to `to`, with `replacement` at `location`.
	private def replace(location, replacement, within:, to:)
		before = @source.byteslice(within, location.start_offset - within)
		after = @source.byteslice(location.end_offset, to - location.end_offset)
		"#{before}#{replacement}#{after}"
	end
end
