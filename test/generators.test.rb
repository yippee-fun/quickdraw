# frozen_string_literal: true

class GeneratorsTest < Quickdraw::Test
	def simplest(generator)
		Quickdraw::Choices.new.draw(generator)
	end

	def samples(generator, count = 500)
		random = Random.new(1)
		Array.new(count) { Quickdraw::Choices.new(Quickdraw::Choices::EMPTY, random).draw(generator) }
	end

	describe "integer" do
		test "stays in its range" do
			check(integer(-3..7)) { |n| assert_includes(-3..7, n) }
			check(integer(1...4)) { |n| assert_includes 1..3, n }
			check(integer(..-10)) { |n| assert_operator n, :<=, -10 }
			check(integer(10..)) { |n| assert_operator n, :>=, 10 }
		end

		test "covers both signs, small values and its bounds" do
			values = samples(integer(-1000..1000))

			assert values.any?(&:negative?)
			assert values.any?(&:positive?)
			assert_includes values, 0
			assert_includes values, 1000
			assert_includes values, -1000
		end

		test "is simplest at zero, or the bound nearest it" do
			assert_equal simplest(integer), 0
			assert_equal simplest(integer(5..10)), 5
			assert_equal simplest(integer(-10..-5)), -5
		end

		test "rejects empty and non-integer ranges" do
			assert_raises(ArgumentError) { integer(5..1) }
			assert_raises(ArgumentError) { integer(1...1) }
			assert_raises(ArgumentError) { integer(1.0..2.0) }
		end
	end

	describe "float" do
		test "stays in its range, and is finite" do
			check(float(-1.5..2.5)) { |f| assert_includes(-1.5..2.5, f) }
			check(float(0...1)) { |f| assert_operator f, :<, 1.0 }
			check(float) { |f| assert f.finite? }
		end

		test "includes whole and fractional values" do
			values = samples(float)

			assert values.any? { |it| it == it.floor }
			assert values.any? { |it| it != it.floor }
		end

		test "is simplest at zero" do
			assert_equal simplest(float), 0.0
			assert_equal simplest(float(2..3)), 2.0
		end

		test "stays inside narrow ranges, with values between their bounds" do
			check(float(0.001..0.009), cases: 1000) { |f| assert_includes 0.001..0.009, f }
			assert samples(float(0.0..1e-18)).any? { |it| it > 0 && it < 1e-18 }
		end

		test "rejects ranges without finite floats" do
			assert_raises(ArgumentError) { float(Float::INFINITY..) }
			assert_raises(ArgumentError) { float(..-Float::INFINITY) }
			assert_raises(ArgumentError) { float(2.0..1.0) }
		end
	end

	test "boolean" do
		assert_equal samples(boolean).uniq.sort_by { |it| it ? 1 : 0 }, [false, true]
		assert_equal simplest(boolean), false
	end

	describe "string" do
		test "uses the characters and lengths given" do
			check(string("ab", length: 2..4)) { |s| assert_match s, /\A[ab]{2,4}\z/ }
			check(string("a".."c", length: 3)) { |s| assert_match s, /\A[abc]{3}\z/ }
			check(string(:ascii)) { |s| assert_match s, /\A[ -~]*\z/ }
			check(string(one_of("x", "y"))) { |s| assert_match s, /\A[xy]*\z/ }
		end

		test "makes valid UTF-8 from any codepoint but surrogates" do
			check(string) do |s|
				assert_equal s.encoding, Encoding::UTF_8
				assert s.valid_encoding?
			end

			assert samples(string).join.each_char.any? { |it| it.ord > 127 }
		end

		test "is simplest empty, then with letters" do
			assert_equal simplest(string), ""
			assert_equal simplest(string(length: 2)), "aa"
		end

		test "maps every index to a distinct codepoint" do
			last = Quickdraw::Generators::UNICODE_SIZE - Quickdraw::Generators::PRINTABLE.size - 1

			assert_equal Quickdraw::Generators.codepoint(0), 0
			assert_equal Quickdraw::Generators.codepoint(32), 127
			assert_equal Quickdraw::Generators.codepoint(last), 0x10FFFF
			refute_includes(0xD800..0xDFFF, Quickdraw::Generators.codepoint(32 + 0xD800 - 127))
		end
	end

	test "symbol" do
		check(symbol) { |s| assert_match s.name, /\A[a-z]+\z/ }
		assert_equal simplest(symbol), :a
	end

	describe "array" do
		test "has lengths in range" do
			check(array(boolean, length: 2..3)) { |list| assert_includes 2..3, list.size }
			check(array(integer, length: 4)) { |list| assert_equal list.size, 4 }
		end

		test "varies in length" do
			assert_operator samples(array(boolean)).map(&:size).uniq.size, :>, 5
		end

		test "rejects negative lengths" do
			assert_raises(ArgumentError) { array(integer, length: -1) }
			assert_raises(ArgumentError) { array(integer, length: ..-1) }
		end
	end

	test "hash_of" do
		check(hash_of(symbol, integer, length: 1..3)) do |hash|
			assert_includes 1..3, hash.size
			assert hash.each_pair.all? { |key, value| Symbol === key && Integer === value }
		end

		check(hash_of(integer(1..10), boolean, length: 10)) { |hash| assert_equal hash.keys.sort, [*1..10] }
	end

	test "fixed_hash" do
		check(fixed_hash(:name => string, "age" => integer(0..120))) do |hash|
			assert_equal hash.keys, [:name, "age"]
			assert_includes 0..120, hash["age"]
		end
	end

	test "tuple" do
		check(tuple(boolean, symbol)) { |pair| match { pair => [true | false, Symbol] } }
	end

	test "one_of mixes constants and generators" do
		assert_equal samples(one_of(:a, :b, integer(1..1))).uniq.sort_by(&:to_s), [1, :a, :b]
		assert_equal simplest(one_of(:a, integer)), :a
		assert_raises(ArgumentError) { one_of }
	end

	test "constant and nilable" do
		check(constant(:fixed)) { |value| assert_equal value, :fixed }
		assert_equal samples(nilable(boolean)).uniq.size, 3
		assert_equal simplest(nilable(integer)), nil
	end

	describe "composition" do
		test "map" do
			check(integer.map { |n| n * 2 }) { |n| assert n.even? }
		end

		test "filter" do
			check(integer.filter(&:odd?)) { |n| assert n.odd? }
		end

		test "flat_map" do
			check(integer(1..5).flat_map { |n| tuple(constant(n), array(boolean, length: n)) }) do |n, list|
				assert_equal list.size, n
			end
		end

		test "generator draws from others" do
			point = generator { |choices| { x: choices.draw(integer(0..9)), y: choices.draw(integer(0..9)) } }

			check(point) { |it| assert_includes 0..18, it[:x] + it[:y] }
		end

		test "drawing something that isn't a generator raises" do
			assert_raises(ArgumentError) { simplest(integer.flat_map { |n| n }) }
		end
	end
end
