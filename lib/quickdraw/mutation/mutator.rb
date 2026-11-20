# frozen_string_literal: true

require "prism"

# Finds the mutants of a source file: changes to the code in its methods that
# a test running that code should notice. Only methods defined directly in
# classes, modules, `class << self`, and the blocks of `Data.define`,
# `Struct.new` (assigned to a constant) and `class_methods`, which a worker
# can redefine.
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

	METHODS = Quickdraw.deep_freeze({
		select: ["reject"],
		filter: ["reject"],
		reject: ["select"],
		any?: ["none?", "all?"],
		all?: ["any?"],
		none?: ["any?"],
		first: ["last"],
		last: ["first"],
		min: ["max"],
		max: ["min"],
		min_by: ["max_by"],
		max_by: ["min_by"],
		positive?: ["negative?"],
		negative?: ["positive?"],
		ceil: ["floor"],
		floor: ["ceil"],
		succ: ["pred"],
		pred: ["succ"],
		upcase: ["downcase"],
		downcase: ["upcase"],
		start_with?: ["end_with?"],
		end_with?: ["start_with?"],
		take: ["drop"],
		drop: ["take"],
		take_while: ["drop_while"],
		drop_while: ["take_while"],
		map: ["each"],
		flat_map: ["map"],
		reverse_each: ["each"],
		public_send: ["send"],
		is_a?: ["instance_of?"],
		kind_of?: ["instance_of?"],
	})

	# Calls that return their receiver changed, which code still runs without.
	TRANSFORMS = [:dup, :to_s, :to_a, :to_h, :to_sym, :to_i, :to_f, :strip, :lstrip, :rstrip, :chomp, :squeeze, :compact, :uniq, :flatten, :sort, :sort_by, :reverse, :abs].freeze

	# Core methods whose last positional argument is optional, and how many
	# they require before it.
	OPTIONAL_ARGUMENTS = { join: 0, split: 0, round: 0, sum: 0, flatten: 0, rjust: 1, ljust: 1, center: 1, fetch: 1 }.freeze

	# Methods that raise without a block.
	BLOCK_REQUIRED = [:lambda, :proc, :tap, :then, :yield_self, :synchronize, :define_method, :instance_eval, :instance_exec, :class_eval, :class_exec, :module_eval, :module_exec, :catch].freeze

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

		# As its magic comment says, so mutants parse and evaluate without it.
		@source = @source.dup.force_encoding(result.source.encoding)
		@line_starts = result.source.offsets
		@frozen_string_literal = result.magic_comments.any? do |comment|
			comment.key.tr("-", "_").casecmp?("frozen_string_literal") && comment.value.casecmp?("true")
		end
		@definitions = definitions(result.value).group_by(&:name)
		# Statements whose value is thrown away, those removed, and calls to
		# `to_s` that interpolation would make anyway.
		@unused = {}.compare_by_identity
		@removed = {}.compare_by_identity
		@interpolated = {}.compare_by_identity
		@mutants = []
		scope(result.value.statements, [])

		lines ? @mutants.select { |mutant| lines.any? { |line| line.between?(mutant.line, mutant.last_line) } } : @mutants
	end

	private def scope(body, nesting)
		return unless Prism::StatementsNode === body

		body.body.each do |node|
			case node
			in Prism::ClassNode then scope(node.body, [*lexical(nesting), ["class", node.constant_path.slice]])
			in Prism::ModuleNode then scope(node.body, [*lexical(nesting), ["module", node.constant_path.slice]])
			in Prism::SingletonClassNode[expression: Prism::SelfNode] then scope(node.body, [*nesting, ["class", "<< self"]])
			in Prism::ConstantWriteNode | Prism::ConstantPathWriteNode then defined_class(node, nesting)
			# ActiveSupport::Concern's, which defines its methods in the module's
			# ClassMethods. Other DSLs by that name may define them elsewhere.
			in Prism::CallNode[receiver: nil | Prism::SelfNode, name: :class_methods, arguments: nil, block: Prism::BlockNode[body: block_body]] if (nesting.last in ["module", _]) && concern?(body)
				scope(block_body, [*nesting, ["class_eval", "ClassMethods"]])
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

	# Whether a module's body extends a Concern, such as ActiveSupport::Concern.
	private def concern?(statements)
		statements.body.any? do |node|
			case node
			in Prism::CallNode[receiver: nil | Prism::SelfNode, name: :extend, arguments: Prism::ArgumentsNode[arguments: [Prism::ConstantReadNode | Prism::ConstantPathNode => constant]]]
				constant.slice.split("::").last == "Concern"
			else false
			end
		end
	end

	# A class made by `Data.define` or `Struct.new` with a block, named by the
	# constant it's assigned to, as in `Point = Data.define(:x, :y) do … end`.
	private def defined_class(node, nesting)
		return unless node.value in Prism::CallNode[
			receiver: Prism::ConstantReadNode | Prism::ConstantPathNode[parent: nil] => receiver,
			name:,
			block: Prism::BlockNode[body:],
		]

		return unless [receiver.name, name] in [:Data, :define] | [:Struct, :new]

		constant = case node
		in Prism::ConstantWriteNode then node.name_loc.slice
		in Prism::ConstantPathWriteNode then node.target.slice
		end

		scope(body, [*lexical(nesting), ["class_eval", constant]])
	end

	# Where a constant defined here goes: not in a block's class, since a block
	# keeps the constant scope around it.
	private def lexical(nesting)
		nesting = nesting.dup
		nesting.pop while nesting.last in ["class_eval", _]
		nesting
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
		@heredocs = heredocs(node.body)
		replace_body(node.body)
		visit(node.body, line)
	end

	# `statement_line` is the line of the innermost statement around `node`.
	private def visit(node, statement_line)
		case node
		in Prism::StatementsNode
			node.body.each_with_index do |statement, index|
				if index < node.body.size - 1
					@unused[statement] = true
					@removed[statement] = true if remove(statement)
				end

				visit(statement, first_line(statement))
			end

			return
		in Prism::DefNode | Prism::ClassNode | Prism::ModuleNode | Prism::SingletonClassNode
			return
		in Prism::CallNode
			invocation(node, statement_line)
		in Prism::AndNode | Prism::OrNode
			replacement = LOGICAL.fetch(node.operator)
			add(node.operator_loc, replacement, "#{node.operator} → #{replacement}", statement_line)
			add(node.location, node.left.slice, "a #{node.operator} b → a", statement_line)
			add(node.location, node.right.slice, "a #{node.operator} b → b", statement_line)
		in Prism::IfNode | Prism::UnlessNode
			condition(node, statement_line)
		in Prism::WhileNode | Prism::UntilNode
			# The loop stops at once, unless that's what removing it does.
			stop = (Prism::WhileNode === node) ? "false" : "true"
			add(node.predicate.location, stop, "condition → #{stop}", statement_line) unless @removed.key?(node) && !node.begin_modifier?
			@unused[node.statements.body.last] = true if node.statements
		in Prism::CaseNode | Prism::CaseMatchNode
			branches(node, statement_line)
		in Prism::RescueNode[statements: Prism::StatementsNode => statements]
			replace_with_nil(statements, "replaced the rescue body with nil")
		in Prism::EnsureNode[statements: Prism::StatementsNode => statements]
			replace_with_nil(statements, "removed the ensure body")
			@unused[statements.body.last] = true
		in Prism::RescueModifierNode[expression:, rescue_expression:]
			add(node.location, expression.slice, "removed the rescue", statement_line)
			add(rescue_expression.location, "nil", "rescued value → nil", statement_line)
		in Prism::ReturnNode | Prism::NextNode | Prism::BreakNode
			jump(node, statement_line)
		in Prism::SuperNode
			last = [node.rparen_loc, node.arguments&.location, (node.block.location if Prism::BlockArgumentNode === node.block)].compact.max_by(&:end_offset)
			add(span(node.keyword_loc.start_offset, last.end_offset), "super()", "super(…) → super()", statement_line)
		in Prism::ForwardingSuperNode
			# Prism 1 has no keyword_loc here.
			add(span(node.location.start_offset, node.location.start_offset + "super".bytesize), "super()", "super → super()", statement_line) if forwarded_parameters.any?
		in Prism::YieldNode[arguments: Prism::ArgumentsNode]
			add(node.location, "yield", "removed the yield arguments", statement_line)
		in Prism::LocalVariableOperatorWriteNode | Prism::InstanceVariableOperatorWriteNode | Prism::ClassVariableOperatorWriteNode | Prism::GlobalVariableOperatorWriteNode | Prism::IndexOperatorWriteNode | Prism::CallOperatorWriteNode if ARITHMETIC.key?(node.binary_operator)
			arithmetic(node.binary_operator_loc, node.binary_operator, node.value, [node.value], statement_line, "=")
		in Prism::LocalVariableOrWriteNode | Prism::InstanceVariableOrWriteNode | Prism::IndexOrWriteNode | Prism::CallOrWriteNode
			or_write(node, statement_line)
		in Prism::EmbeddedStatementsNode[statements: Prism::StatementsNode[body: [Prism::CallNode[name: :to_s, arguments: nil, block: nil] => call]]]
			@interpolated[call] = true
		in Prism::TrueNode
			add(node.location, "false", "true → false", statement_line)
		in Prism::FalseNode
			add(node.location, "true", "false → true", statement_line)
		in Prism::IntegerNode
			[node.value + 1, 0].each do |value|
				add(node.location, value.to_s, "#{node.slice} → #{value}", statement_line) unless value == node.value
			end
		in Prism::FloatNode
			[node.value + 1, 0.0].each do |value|
				add(node.location, value.to_s, "#{node.slice} → #{value}", statement_line) unless value == node.value
			end
		in Prism::StringNode[opening_loc: Prism::Location => opening] unless opening.slice.start_with?("<<") || node.unescaped.empty?
			add(node.location, '""', "#{abbreviate(node.slice)} → \"\"", statement_line)
		in Prism::InterpolatedStringNode[opening_loc: Prism::Location => opening] unless opening.slice.start_with?("<<")
			add(node.location, '""', "#{abbreviate(node.slice)} → \"\"", statement_line)
		in Prism::RegularExpressionNode | Prism::InterpolatedRegularExpressionNode
			add(node.location, "/(?!)/", "regexp → never matches", statement_line)
		in Prism::ArrayNode[opening_loc: Prism::Location, elements: [_, *] => elements]
			add(node.location, "[]", "#{abbreviate(node.slice)} → []", statement_line)
			remove_each(elements, statement_line) if elements.size > 1
		in Prism::HashNode[elements: [_, *] => elements]
			add(node.location, "{}", "#{abbreviate(node.slice)} → {}", statement_line)
			remove_each(elements, statement_line) if elements.size > 1
		in Prism::RangeNode[right: Prism::Node, operator_loc:]
			replacement = node.exclude_end? ? ".." : "..."
			add(operator_loc, replacement, "#{operator_loc.slice} → #{replacement}", statement_line)
		else nil
		end

		node.compact_child_nodes.each { |child| visit(child, statement_line) }
	end

	private def invocation(node, line)
		case node
		in { name: :! | :not, receiver: Prism::Node => receiver, arguments: nil }
			add(node.location, receiver.slice, "removed the negation", line)
		in { receiver: Prism::Node => receiver, arguments: Prism::ArgumentsNode[arguments: [argument]], message_loc: Prism::Location => message } if COMPARISONS.key?(node.name) || ARITHMETIC.key?(node.name)
			if (replacement = COMPARISONS[node.name])
				add(message, replacement, "#{node.name} → #{replacement}", line)
			else
				arithmetic(message, node.name, argument, [receiver, argument], line)
			end
		else
			swap(node, line)
			add(node.call_operator_loc, ".", "&. → .", line) if node.safe_navigation?
			unwrap(node, line)
			fetch_to_index(node, line)
			remove_arguments(node, line)
			remove_block(node, line)
		end
	end

	# Not where both operators give the same (x + 0), or concatenating strings
	# or arrays, where the other operator raises.
	private def arithmetic(location, name, argument, operands, line, suffix = "")
		return if operands.any? { |operand| operand in Prism::StringNode | Prism::InterpolatedStringNode | Prism::ArrayNode }
		return if (argument in Prism::IntegerNode) && argument.value == IDENTITIES[name]

		replacement = "#{ARITHMETIC.fetch(name)}#{suffix}"
		add(location, replacement, "#{name}#{suffix} → #{replacement}", line)
	end

	# Not when the call's value is thrown away, unless it does more than return one.
	private def swap(node, line)
		return unless node.receiver && node.message_loc
		return if @unused.key?(node) && !(node.name in :reverse_each | :public_send)

		METHODS.fetch(node.name, []).each do |replacement|
			add(node.message_loc, replacement, "#{node.name} → #{replacement}", line)
		end
	end

	# `foo.strip` to `foo`, unless `foo` is a literal it wouldn't change.
	private def unwrap(node, line)
		receiver = node.receiver
		return unless receiver && TRANSFORMS.include?(node.name)
		return if @unused.key?(node) || @interpolated.key?(node)
		return if [node.name, receiver] in [:to_s, Prism::StringNode | Prism::InterpolatedStringNode] | [:to_a, Prism::ArrayNode] | [:to_h, Prism::HashNode] | [:to_sym, Prism::SymbolNode] | [:to_i, Prism::IntegerNode] | [:to_f, Prism::FloatNode]

		add(node.location, receiver.slice, "removed .#{node.name}", line)
	end

	# `hash.fetch(key)` to `hash[key]`, which gives nil rather than raising.
	# Not after `&.`, which `[]` would drop.
	private def fetch_to_index(node, line)
		return unless node in {
			name: :fetch,
			receiver: Prism::Node,
			call_operator_loc: Prism::Location => operator,
			arguments: Prism::ArgumentsNode[arguments: [Prism::Node => key]],
			block: nil,
		}

		return if node.safe_navigation? || (key in Prism::SplatNode | Prism::KeywordHashNode)

		add(span(operator.start_offset, node.location.end_offset), "[#{key.slice}]", "fetch → []", line)
	end

	# Each argument, keyword argument and block argument that's removable?,
	# but not from operators or attribute writers.
	private def remove_arguments(node, line)
		return if node.attribute_write? || !node.name.match?(/\A[[:alpha:]_]/)

		arguments = (node.arguments&.arguments || []).flat_map do |argument|
			case argument
			in Prism::KeywordHashNode[elements:] then elements
			else [argument]
			end
		end
		arguments << node.block if Prism::BlockArgumentNode === node.block

		arguments.each_index do |index|
			next unless removable?(node, arguments, index)

			# As in `puts value`, whose space would otherwise be left behind.
			location = if arguments.size == 1 && !node.opening_loc
				span(node.message_loc.end_offset, arguments.first.location.end_offset)
			else
				cut(arguments, index)
			end

			add(location, "", "removed an argument", line)
		end
	end

	# Whether the call could still work without `arguments[index]`, and do
	# something else: so not an argument that any method this file defines
	# with that name requires or has as its default, nor a positional argument
	# to some other method, which would almost always raise ArgumentError,
	# unless it's one of the core methods' optional ones, nor the block a
	# method needs.
	private def removable?(node, arguments, index)
		argument = arguments.fetch(index)
		definitions = @definitions[node.name]

		case argument
		in Prism::BlockArgumentNode
			!BLOCK_REQUIRED.include?(node.name)
		in Prism::AssocSplatNode
			true
		in Prism::AssocNode[key: Prism::SymbolNode[unescaped: String => key], value:]
			definitions.nil? || definitions.all? { |definition| optional_keyword?(definition, key.to_sym, value) }
		in Prism::AssocNode
			true
		else
			positional = arguments.reject { |it| it in Prism::AssocNode | Prism::AssocSplatNode | Prism::BlockArgumentNode }
			return false if positional.any? { |it| it in Prism::SplatNode | Prism::ForwardingArgumentsNode }

			if definitions
				definitions.all? { |definition| optional_positional?(definition, positional, argument) }
			else
				required = OPTIONAL_ARGUMENTS[node.name] or return false
				argument.equal?(positional.last) && positional.size > required
			end
		end
	end

	private def optional_keyword?(definition, name, value)
		case definition.parameters&.keywords&.find { |keyword| keyword.name == name }
		in Prism::RequiredKeywordParameterNode then false
		in Prism::OptionalKeywordParameterNode => keyword then !same_literal?(keyword.value, value)
		else true
		end
	end

	private def optional_positional?(definition, positional, argument)
		parameters = definition.parameters or return false
		return false if positional.size <= parameters.requireds.size + parameters.posts.size
		return true unless argument.equal?(positional.last) && parameters.posts.empty?

		# The optional parameter the last argument fills, if not the rest.
		filled = parameters.optionals[positional.size - 1 - parameters.requireds.size]
		filled.nil? || !same_literal?(filled.value, argument)
	end

	# Whether a default and an argument are the same literal, which, unlike
	# other code, means the same in the caller and the method.
	private def same_literal?(default, argument)
		(default in Prism::IntegerNode | Prism::FloatNode | Prism::StringNode | Prism::SymbolNode | Prism::NilNode | Prism::TrueNode | Prism::FalseNode) &&
			default.slice == argument.slice
	end

	private def remove_block(node, line)
		return unless Prism::BlockNode === node.block
		return if BLOCK_REQUIRED.include?(node.name)

		before = [node.receiver&.location, node.message_loc, node.arguments&.location, node.closing_loc].compact.max_by(&:end_offset)
		add(span(before.end_offset, node.block.location.end_offset), "", "removed the block", line)
	end

	private def condition(node, line)
		negate(node.predicate, line)

		# Skipping an `if` without an `else` does what removing it does.
		skipping = case node
		in Prism::IfNode[subsequent: nil] if @removed.key?(node) then "false"
		in Prism::UnlessNode[else_clause: nil] if @removed.key?(node) then "true"
		else nil
		end

		["true", "false"].each do |value|
			add(node.predicate.location, value, "condition → #{value}", line) unless value == skipping
		end
	end

	# Not when the condition is already negated, since removing that negation does the same.
	private def negate(predicate, statement_line)
		return if predicate in Prism::CallNode[name: :! | :not]

		add(predicate.location, "!(#{predicate.slice})", "negated the condition", statement_line)
	end

	private def branches(node, line)
		return if node.conditions.size < 2

		keyword = (Prism::CaseNode === node) ? "when" : "in"
		node.conditions.each { |branch| add(branch.location, "", "removed the #{keyword} branch", line) }
	end

	# Covered by the tests that run it, since only an exception, or leaving,
	# does.
	private def replace_with_nil(statements, description)
		add(statements.location, "nil", description, first_line(statements.body.first))
	end

	# The first line of `node` that runs: inside a `begin` or parentheses, and
	# the first `when` of a `case` without a subject, whose own lines don't.
	private def first_line(node)
		case node
		in Prism::BeginNode[statements: Prism::StatementsNode[body: [first, *]]] then first_line(first)
		in Prism::ParenthesesNode[body: Prism::StatementsNode[body: [first, *]]] then first_line(first)
		in Prism::CaseNode[predicate: nil, conditions: [first, *]] then first.location.start_line
		else node.location.start_line
		end
	end

	private def jump(node, line)
		return if node.arguments.nil? || (node.arguments.arguments in [Prism::NilNode])

		add(span(node.keyword_loc.end_offset, node.arguments.location.end_offset), "", "removed the #{node.keyword_loc.slice} value", line)
	end

	# Not a local variable first assigned here, which is nil before.
	private def or_write(node, line)
		return if (node in Prism::LocalVariableOrWriteNode[depth: 0]) && !assigned_before?(node.name, node.location.start_offset, @method)

		add(node.operator_loc, "=", "||= → =", line)
	end

	# Whether `name` is a parameter or assigned before `offset` in `node`.
	private def assigned_before?(name, offset, node)
		return false if node.location.start_offset >= offset

		case node
		in Prism::LocalVariableWriteNode | Prism::LocalVariableTargetNode | Prism::LocalVariableOperatorWriteNode | Prism::LocalVariableAndWriteNode | Prism::LocalVariableOrWriteNode | Prism::RequiredParameterNode | Prism::OptionalParameterNode | Prism::RestParameterNode | Prism::RequiredKeywordParameterNode | Prism::OptionalKeywordParameterNode | Prism::KeywordRestParameterNode | Prism::BlockParameterNode if node.name == name
			true
		else
			node.compact_child_nodes.any? { |child| assigned_before?(name, offset, child) }
		end
	end

	# The method's parameters but its block, which `super` passes on.
	private def forwarded_parameters
		parameters = @method.parameters or return []
		[*parameters.requireds, *parameters.optionals, parameters.rest, *parameters.posts, *parameters.keywords, parameters.keyword_rest].compact
	end

	private def remove_each(nodes, line)
		nodes.each_with_index { |node, index| add(cut(nodes, index), "", "removed #{abbreviate(node.slice)}", line) }
	end

	# Code on one line and short enough for a description, so it can say
	# which of several literals on a line a mutant changes.
	private def abbreviate(code)
		code = Quickdraw.utf8(code).gsub(/\s*\n\s*/, " ")
		(code.size > ABBREVIATION) ? "#{code[0, ABBREVIATION - 1]}…" : code
	end

	ABBREVIATION = 30

	private def remove(statement)
		case statement
		in Prism::LocalVariableWriteNode | Prism::LocalVariableOperatorWriteNode | Prism::LocalVariableOrWriteNode | Prism::LocalVariableAndWriteNode | Prism::MultiWriteNode
			nil
		in Prism::NilNode | Prism::TrueNode | Prism::FalseNode | Prism::IntegerNode | Prism::StringNode | Prism::SymbolNode
			nil
		else
			add(statement.location, "nil", "removed the statement", first_line(statement))
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
		# Leaving a heredoc's body behind, which then runs as code.
		return if @heredocs.any? { |heredoc| location.start_offset <= heredoc.start_offset && heredoc.start_offset < location.end_offset && location.end_offset < heredoc.end_offset }

		# With the lines it replaces, so the code after it keeps its line numbers.
		padding = "\n" * [location.slice.count("\n") - replacement.count("\n"), 0].max
		source = replace(location, "#{replacement}#{padding}", within: @method.location.start_offset, to: @method.location.end_offset)
		return if @seen.key?(source)

		@seen[source] = true
		result = Prism.parse(source, encoding: @source.encoding)
		# Such as an endless method whose heredoc's body is after its end, or
		# removing a local variable's only assignment, which only breaks the
		# code that reads it.
		return if result.failure? || reads_removed_local?(result.value)

		line = location.start_line
		last_line = location.end_line
		line_start = @line_starts.fetch(line - 1)
		line_end = (@line_starts[last_line] || @source.bytesize)
		after = replace(location, replacement, within: line_start, to: line_end).chomp

		@mutants << Quickdraw::Mutation::Mutant.new(
			id: nil,
			subject: @subject,
			line:,
			last_line:,
			covering_line:,
			description:,
			source:,
			frozen_string_literal: @frozen_string_literal,
			before: Quickdraw.utf8(@source.byteslice(line_start, line_end - line_start).chomp),
			after: after.strip.empty? ? "" : Quickdraw.utf8(after),
		)
	end

	# Where to cut `nodes[index]` from a comma-separated list, with a comma beside it.
	private def cut(nodes, index)
		location = nodes.fetch(index).location

		if nodes.size == 1 then location
		elsif index < nodes.size - 1 then span(location.start_offset, nodes[index + 1].location.start_offset)
		else span(nodes[index - 1].location.end_offset, location.end_offset)
		end
	end

	private def span(start_offset, end_offset)
		@method.location.copy(start_offset:, length: end_offset - start_offset)
	end

	# The heredocs in `node`, from their openings to the ends of their bodies.
	private def heredocs(node)
		nested = node.compact_child_nodes.flat_map { |child| heredocs(child) }

		case node
		in Prism::StringNode | Prism::InterpolatedStringNode | Prism::XStringNode | Prism::InterpolatedXStringNode if node.heredoc?
			[span(node.opening_loc.start_offset, node.closing_loc.end_offset), *nested]
		else nested
		end
	end

	# Every method definition in `node`.
	private def definitions(node)
		nested = node.compact_child_nodes.flat_map { |child| definitions(child) }
		(Prism::DefNode === node) ? [node, *nested] : nested
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
		# Interpolating ASCII-only strings gives UTF-8 on some Rubies.
		"#{before}#{replacement}#{after}".force_encoding(@source.encoding)
	end
end
