# frozen_string_literal: true

# Formats values one element per line, so failure messages can diff them line
# by line. Runs alongside user code, so it must only use core Ruby.
module Quickdraw::Inspector
	extend self

	INDENT = "  "
	# Not on TruffleRuby, which defines to_h on each Data class rather than on Data.
	DATA_TO_H = (Data.instance_method(:to_h) if Data.method_defined?(:to_h))
	PUBLIC_SEND = Kernel.instance_method(:public_send)
	STRUCT_EACH_PAIR = Struct.instance_method(:each_pair)

	def pretty(value)
		format(value, 0, {}.compare_by_identity)
	end

	private def format(value, depth, seen)
		return "#{value.class}(…)" if seen.key?(value)

		case value
		in Hash unless value.empty?
			nested(value, seen) do
				entries = value.map { |key, item| "#{key(key)}#{format(item, depth + 1, seen)}" }
				container("{", "}", entries, depth)
			end
		in Array unless value.empty?
			nested(value, seen) do
				container("[", "]", value.map { |item| format(item, depth + 1, seen) }, depth)
			end
		in Set unless value.empty?
			nested(value, seen) do
				container("#<Set {", "}>", value.map { |item| format(item, depth + 1, seen) }, depth)
			end
		# Through Data and Struct's own methods, since a member can be named to_h or each_pair.
		in Data
			nested(value, seen) do
				members = DATA_TO_H ? DATA_TO_H.bind_call(value) : value.class.members.to_h { |member| [member, PUBLIC_SEND.bind_call(value, member)] }
				fields = members.map { |name, item| "#{name}: #{format(item, depth + 1, seen)}" }
				container("#<data #{class_name(value)}", ">", fields, depth)
			end
		in Struct
			nested(value, seen) do
				fields = STRUCT_EACH_PAIR.bind_call(value).map { |name, item| "#{name}: #{format(item, depth + 1, seen)}" }
				container("#<struct #{class_name(value)}", ">", fields, depth)
			end
		else
			if default_inspect?(value) && value.instance_variables.any?
				nested(value, seen) do
					fields = value.instance_variables.map { |name| "#{name}: #{format(value.instance_variable_get(name), depth + 1, seen)}" }
					container("#<#{class_name(value)}", ">", fields, depth)
				end
			else
				value.inspect
			end
		end
	end

	private def nested(value, seen)
		seen[value] = true
		yield
	ensure
		seen.delete(value)
	end

	private def container(open, close, items, depth)
		inner = INDENT * (depth + 1)
		"#{open}\n#{items.map { |item| "#{inner}#{item},\n" }.join}#{INDENT * depth}#{close}"
	end

	# Hash keys as Ruby 3.4 writes them: `name: ` for symbols, `key => ` otherwise.
	private def key(key)
		case key
		in Symbol
			inspected = key.inspect
			inspected.start_with?(':"') ? "#{inspected.delete_prefix(':')}: " : "#{key.name}: "
		else
			"#{key.inspect} => "
		end
	end

	# Without the anonymous module each test file is loaded in.
	private def class_name(value)
		value.class.name&.gsub(/#<Module:0x\h+>::/, "") || value.class.inspect
	end

	# Kernel#inspect includes the object's address, which would differ even
	# between equal objects; a custom inspect is shown as written.
	private def default_inspect?(value)
		value.method(:inspect).owner == Kernel
	rescue NameError
		false
	end
end
