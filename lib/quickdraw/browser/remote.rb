# frozen_string_literal: true

# A Playwright object in the worker's Node process, such as a Page or Locator,
# with calls on it not sent yet. Its methods are Playwright's, in snake case,
# with options as keywords and predicates ending in ?, for is…:
#
#   page.get_by_role("button", name: "Go").click   # getByRole("button", { name: "Go" }).click()
#   page.locator("li").first.visible?              # locator("li").first().isVisible()
#
# Methods that return a locator, frame locator or the like without waiting
# (see LAZY) are sent with the next call that needs an answer, so each line
# above is one round trip. Results that aren't JSON come back as Remotes.
class Quickdraw::Browser::Remote < BasicObject
	LAZY = ::Set[
		"locator", "getByRole", "getByText", "getByLabel", "getByPlaceholder", "getByAltText", "getByTitle", "getByTestId",
		"filter", "first", "last", "nth", "and", "or", "frameLocator", "contentFrame", "owner", "describe",
		"keyboard", "mouse", "touchscreen", "clock",
	].freeze

	# Ruby's implicit conversions, which aren't Playwright's methods.
	CONVERSIONS = ::Set[:to_ary, :to_str, :to_hash, :to_proc, :to_io, :to_int, :to_path, :to_sym, :to_a, :to_h].freeze

	# A Ruby value from the bridge's result.
	def self.wrap(bridge, value)
		case value
		in ::Hash if value.key?("$handle") then new(bridge, value["$handle"], value["$type"])
		in ::Hash if value.key?("$binary") then value["$binary"].unpack1("m")
		in ::Hash then value.transform_values { |item| wrap(bridge, item) }
		in ::Array then value.map { |item| wrap(bridge, item) }
		else value
		end
	end

	# An argument for the bridge. Symbol keys, as keyword options have, are
	# Playwright's option names, in camel case; string keys are data, as they are.
	def self.argument(value)
		case value
		in ::Quickdraw::Browser::Remote then value.__reference__
		in ::Regexp then { "$regexp" => pattern(value) }
		in ::Hash then value.to_h { |key, item| [(::Symbol === key) ? camel(key.to_s) : key, argument(item)] }
		in ::Array then value.map { |item| argument(item) }
		in ::Symbol then value.to_s
		else value
		end
	end

	# A Regexp as JavaScript's source and flags. Ruby's ^ and $ always match at
	# lines, and its /m is JavaScript's /s.
	def self.pattern(regexp)
		raise ::ArgumentError, "Playwright can’t match with an extended Regexp." if regexp.options.anybits?(::Regexp::EXTENDED)

		source = regexp.source.gsub("\\A", "(?<![\\s\\S])").gsub(/\\[zZ]/, "(?![\\s\\S])").gsub("\\h", "[0-9a-fA-F]")
		{ "source" => source, "flags" => "m#{'i' if regexp.casefold?}#{'s' if regexp.options.anybits?(::Regexp::MULTILINE)}" }
	end

	def self.camel(name) = name.gsub(/_([a-z\d])/) { ::Regexp.last_match(1).upcase }

	def initialize(bridge, handle, type, chain = [], description = nil)
		@bridge = bridge
		@handle = handle
		@type = type
		@chain = chain
		@description = description
	end

	def method_missing(name, *arguments, **options, &block)
		return super if CONVERSIONS.include?(name)
		::Kernel.raise ::ArgumentError, "Playwright’s methods don’t take Ruby blocks." if block

		method = name.end_with?("?") ? "is#{::Quickdraw::Browser::Remote.camel("_#{name.to_s.delete_suffix('?')}")}" : ::Quickdraw::Browser::Remote.camel(name.to_s)
		described = "#{"#{@description}." if @description}#{name}(#{[*arguments.map(&:inspect), *options.map { |key, value| "#{key}: #{value.inspect}" }].join(', ')})"
		arguments << options unless options.empty?
		chain = [*@chain, [method, ::Quickdraw::Browser::Remote.argument(arguments)]]

		if LAZY.include?(method)
			::Quickdraw::Browser::Remote.new(@bridge, @handle, @type, chain, described)
		else
			::Quickdraw::Browser::Remote.wrap(@bridge, @bridge.call("call", target: @handle, chain:))
		end
	end

	def respond_to_missing?(name, _private = false) = !CONVERSIONS.include?(name)

	# The bridge's reference to this object: its handle, and the calls on it.
	def __reference__
		@chain.empty? ? { "$handle" => @handle } : { "$chain" => { "target" => @handle, "chain" => @chain } }
	end

	# A locator for the bridge's waiting assertions.
	def __locator__ = { "target" => @handle, "chain" => @chain, "description" => to_s }

	def __handle__ = @handle

	def to_s = @description || @type
	def inspect = "#<Quickdraw::Browser::Remote #{self}>"
end
