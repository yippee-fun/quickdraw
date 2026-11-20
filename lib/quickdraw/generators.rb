# frozen_string_literal: true

# Generators for properties (see Quickdraw::Test#check). Tests include these
# methods; elsewhere, call them on this module. Helpers are singleton methods,
# so they don't clash with a test's own.
#
# Runs in workers alongside user code, so it must only use core Ruby.
module Quickdraw::Generators
	extend self

	# Printable ASCII, simplest first: what strings shrink towards.
	PRINTABLE = Quickdraw.deep_freeze([*"a".."z", *"A".."Z", *"0".."9", " "].then { |simplest| [*simplest, *((32..126).map(&:chr) - simplest)] })

	# Every codepoint but surrogates, after the printable ones above.
	UNICODE_SIZE = 0x110000 - 0x800

	# One of them beyond ASCII, which a dictionary must be joinable with.
	UNICODE_SAMPLE = "\u0080"

	FRACTIONS = 1 << 52

	def integer(range = nil)
		min, max = Quickdraw::Generators.bounds(range)
		origin = Quickdraw::Generators.origin(min, max, 0)
		above = max && (max - origin)
		below = min && (origin - min)

		Quickdraw::Generator.new do |choices|
			direction, limit = Quickdraw::Generators.direction(choices, above, below)
			origin + (direction * Quickdraw::Generators.magnitude(choices, limit))
		end
	end

	# Finite floats, simplest first: closest to zero, then fewest fractional bits.
	def float(range = nil)
		min, max = Quickdraw::Generators.float_bounds(range)
		origin = Quickdraw::Generators.origin(min, max, 0.0)
		above = max && (max - origin)
		below = min && (origin - min)

		Quickdraw::Generator.new do |choices|
			direction, limit = Quickdraw::Generators.direction(choices, above, below)
			whole = Quickdraw::Generators.magnitude(choices, limit&.floor)
			fraction = choices.choose(FRACTIONS - 1) { |random| (random.rand(2) == 0) ? 0 : random.rand(FRACTIONS) }
			# In a range narrower than 1, fractions span it rather than overshoot it.
			magnitude = whole + (fraction.fdiv(FRACTIONS) * ((limit && limit < 1) ? limit : 1))
			value = origin + (direction * ((limit && magnitude > limit) ? limit : magnitude))
			# Adding to the origin can round past a bound.
			value.clamp(min || -Float::INFINITY, max || Float::INFINITY)
		end
	end

	def boolean
		Quickdraw::Generator.new { |choices| choices.choose(1) == 1 }
	end

	# `characters` is a String or Array of them, a Range such as "a".."z", a
	# generator of characters, :ascii for printable ASCII, or :unicode.
	# `dictionary` has strings, such as a format's keywords, to mix in with the
	# characters, each counting as one towards the length.
	def string(characters = :unicode, length: 0.., dictionary: [])
		piece = Quickdraw::Generators.with_dictionary(Quickdraw::Generators.characters(characters, dictionary), dictionary)
		lengths = Quickdraw::Generators.lengths(length)

		Quickdraw::Generator.new do |choices|
			string = +""
			Quickdraw::Generators.collect(choices, lengths) { string << choices.draw(piece) }
			string
		end
	end

	# Binary strings of any bytes, mixed with `dictionary`'s strings as string does.
	def bytes(length: 0.., dictionary: [])
		byte = Quickdraw::Generator.new { |choices| choices.choose(255).chr }
		piece = Quickdraw::Generators.with_dictionary(byte, dictionary.map { |token| (String === token) ? token.b : token })
		lengths = Quickdraw::Generators.lengths(length)

		Quickdraw::Generator.new do |choices|
			string = String.new(encoding: Encoding::BINARY)
			Quickdraw::Generators.collect(choices, lengths) { string << choices.draw(piece) }
			string
		end
	end

	def symbol(characters = "a".."z", length: 1..)
		string(characters, length:).map(&:to_sym)
	end

	def array(generator, length: 0..)
		lengths = Quickdraw::Generators.lengths(length)

		Quickdraw::Generator.new do |choices|
			Quickdraw::Generators.collect(choices, lengths) { choices.draw(generator) }
		end
	end

	# Hashes of keys and values from the generators. A key already in the hash is
	# drawn again, a few times, before the case is discarded.
	def hash_of(keys, values, length: 0..)
		lengths = Quickdraw::Generators.lengths(length)

		Quickdraw::Generator.new do |choices|
			hash = {}
			new_keys = keys.filter { |key| !hash.key?(key) }
			Quickdraw::Generators.collect(choices, lengths) { hash[choices.draw(new_keys)] = choices.draw(values) }
			hash
		end
	end

	# Hashes with these keys, and values from their generators.
	def fixed_hash(shape)
		Quickdraw::Generator.new do |choices|
			shape.transform_values { |generator| choices.draw(generator) }
		end
	end

	# Arrays of a value from each generator.
	def tuple(*generators)
		Quickdraw::Generator.new do |choices|
			generators.map { |generator| choices.draw(generator) }
		end
	end

	# One of the options, simplest first. An option that's a generator is drawn
	# from, so `one_of(:none, integer)` mixes constants with generated values.
	def one_of(*options)
		raise ::ArgumentError, "one_of needs at least one option." if options.empty?

		Quickdraw::Generator.new do |choices|
			case options[choices.choose(options.size - 1)]
			in Quickdraw::Generator => generator then choices.draw(generator)
			in option then option
			end
		end
	end

	def constant(value)
		Quickdraw::Generator.new { value }
	end

	def nilable(generator)
		one_of(nil, generator)
	end

	# A generator from a block that draws from others, e.g.
	# `generator { |choices| User.new(name: choices.draw(string)) }`.
	def generator(&)
		Quickdraw::Generator.new(&)
	end

	# A choice favouring small values and the limit, as bugs are found there.
	def self.magnitude(choices, limit)
		choices.choose(limit) do |random|
			if limit && random.rand(16) == 0
				limit
			else
				value = random.rand(1 << random.rand((limit ? limit.bit_length : 64) + 1))
				(limit && value > limit) ? random.rand(limit + 1) : value
			end
		end
	end

	# Which way from the origin, positive first, and how far the bounds allow.
	# Chosen even for a magnitude of zero, so a shrunk magnitude doesn't shift
	# the choices after it.
	def self.direction(choices, above, below)
		up = above.nil? || above > 0
		down = below.nil? || below > 0

		if up && down
			(choices.choose(1) == 1) ? [-1, below] : [1, above]
		elsif down
			[-1, below]
		else
			[1, above]
		end
	end

	# The block's results, as many times as `lengths` allows. Each optional item
	# is a span with the choice to add it, so shrinking can delete it.
	def self.collect(choices, (min, max))
		average = [min * 2, min + 5].max
		average = (min + max) / 2.0 if max && (min + max) / 2.0 < average
		stop = 1.0 / (average - min + 1)
		items = Array.new(min) { choices.span { yield } }

		loop do
			break if max && items.size == max

			added = choices.span do
				next false if choices.choose(1) { |random| (random.rand < stop) ? 0 : 1 } == 0

				items << yield
			end

			break unless added
		end

		items
	end

	# What values shrink towards: zero, or the bound nearest it.
	def self.origin(min, max, zero)
		if min && min > zero then min
		elsif max && max < zero then max
		else zero
		end
	end

	def self.bounds(range)
		case range
		in nil
			[nil, nil]
		in Range if (nil === range.begin || Integer === range.begin) && (nil === range.end || Integer === range.end)
			min = range.begin
			max = range.end && (range.exclude_end? ? range.end - 1 : range.end)
			raise ::ArgumentError, "#{range.inspect} is empty." if min && max && min > max

			[min, max]
		else
			raise ::ArgumentError, "Expected a Range of Integers, got #{range.inspect}."
		end
	end

	def self.float_bounds(range)
		case range
		in nil
			[nil, nil]
		in Range if (nil === range.begin || Numeric === range.begin) && (nil === range.end || Numeric === range.end)
			min = range.begin&.to_f
			max = range.end&.to_f
			min = nil if min == -Float::INFINITY
			max = nil if max == Float::INFINITY
			max = max.prev_float if max && range.exclude_end?

			if (min && max && min > max) || min&.nan? || max&.nan? || min == Float::INFINITY || max == -Float::INFINITY
				raise ::ArgumentError, "#{range.inspect} has no finite floats."
			end

			[min, max]
		else
			raise ::ArgumentError, "Expected a Range of numbers, got #{range.inspect}."
		end
	end

	def self.lengths(length)
		min, max = (Integer === length) ? [length, length] : bounds(length)
		min ||= 0
		raise ::ArgumentError, "A length can't be negative, got #{length.inspect}." if min < 0 || (max && max < min)

		[min, max]
	end

	# Those given, joinable with the `dictionary` they're mixed with.
	def self.characters(characters, dictionary = [])
		case characters
		in Quickdraw::Generator then characters
		in :unicode
			joinable([UNICODE_SAMPLE], dictionary)
			unicode
		in :ascii then one_of(*joinable(PRINTABLE, dictionary))
		in String then one_of(*joinable(characters.chars.uniq, dictionary))
		in Range if characters.begin.nil? || characters.end.nil?
			raise ::ArgumentError, "#{characters.inspect} has no #{characters.begin ? 'end' : 'beginning'}, which a Range of characters needs."
		in Range | Array then one_of(*joinable(characters.to_a.uniq, dictionary))
		else raise ::ArgumentError, "Expected characters as a String, Range, Array, generator, :ascii or :unicode, got #{characters.inspect}."
		end
	end

	# The characters, if they and `others` are Strings that are valid in their
	# encodings and can be joined in any order.
	def self.joinable(characters, others = [])
		raise ::ArgumentError, "Expected at least one character." if characters.empty?

		[*characters, *others].each_with_object(+"") do |character, joined|
			raise ::ArgumentError, "Expected characters as Strings, got #{character.inspect}." unless String === character
			raise ::ArgumentError, "#{character.inspect} isn't valid #{character.encoding}." unless character.valid_encoding?

			unless Encoding.compatible?(joined, character)
				raise ::ArgumentError, "#{character.inspect} is #{character.encoding}, which can't be joined with #{joined.encoding} characters."
			end

			joined << character
		end

		characters
	end

	# The generator's values, or a quarter of the time a string from the
	# dictionary. Without one, just the generator, so its choices don't change.
	def self.with_dictionary(generator, dictionary)
		return generator if dictionary.empty?

		unless dictionary.all? { |token| String === token && !token.empty? }
			raise ::ArgumentError, "A dictionary has non-empty strings, got #{dictionary.inspect}."
		end

		tokens = joinable(dictionary.uniq).map { |token| token.dup.freeze }

		Quickdraw::Generator.new do |choices|
			if choices.choose(1) { |random| (random.rand(4) == 0) ? 1 : 0 } == 1
				tokens[choices.choose(tokens.size - 1)]
			else
				choices.draw(generator)
			end
		end
	end

	def self.unicode
		Quickdraw::Generator.new do |choices|
			index = choices.choose(UNICODE_SIZE - 1) do |random|
				(random.rand(4) == 0) ? random.rand(UNICODE_SIZE) : random.rand(PRINTABLE.size)
			end

			(index < PRINTABLE.size) ? PRINTABLE[index] : codepoint(index - PRINTABLE.size).chr(Encoding::UTF_8)
		end
	end

	# The nth codepoint that isn't printable ASCII or a surrogate.
	def self.codepoint(index)
		controls = 32
		below_surrogates = 0xD800 - 127

		if index < controls then index
		elsif index < controls + below_surrogates then index - controls + 127
		else index - controls - below_surrogates + 0xE000
		end
	end
end
