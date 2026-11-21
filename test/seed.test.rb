# frozen_string_literal: true

require "random/formatter"

class SeedTest < Quickdraw::Test
	READERS = {
		"rand" => -> { rand },
		"rand with a limit" => -> { rand(1_000_000) },
		"Kernel.rand" => -> { Kernel.rand },
		"srand" => -> { srand },
		"srand with a seed" => -> { [srand(7), rand] },
		"Kernel.srand" => -> { [Kernel.srand(7), rand] },
		"Random.srand" => -> { [Random.srand(7), rand] },
		"Random.rand" => -> { Random.rand },
		"Random.random_number" => -> { Random.random_number },
		"Random.bytes" => -> { Random.bytes(8) },
		"Random.seed" => -> { Random.seed },
		"Random.hex" => -> { Random.hex },
		"Random.uuid" => -> { Random.uuid },
		"Random.alphanumeric" => -> { Random.alphanumeric },
		"Array#shuffle" => -> { (1..20).to_a.shuffle },
		"Array#shuffle!" => -> { (1..20).to_a.shuffle! },
		"Array#sample" => -> { (1..1_000_000).to_a.sample },
		"Array#shuffle with Random" => -> { (1..20).to_a.shuffle(random: Random) },
	}.freeze

	def seeded(seed)
		Kernel.srand(seed)
		yield
	end

	READERS.each do |name, reader|
		test "#{name} reads what the seed gives" do
			expected = seeded(1234) { instance_exec(&reader) }

			Quickdraw::Seed.later(1234)
			assert_equal instance_exec(&reader), expected
			assert_equal Quickdraw::Seed.pending, nil

			Quickdraw::Seed.later(1235)
			refute_equal instance_exec(&reader), expected
		end
	end

	test "wraps everything of Random's that reads the default generator" do
		skip "Only CRuby seeds lazily" unless Quickdraw::Seed::LAZY

		assert_equal Random.singleton_methods(false).sort, [:bytes, :new_seed, :rand, :seed, :srand, :urandom]
		assert_equal Random::Formatter.instance_methods(false).sort - [:rand, :random_number], [:alphanumeric, :base64, :hex, :random_bytes, :urlsafe_base64, :uuid, :uuid_v4, :uuid_v7]
	end

	test "waits for the default generator to be read" do
		skip "Only CRuby seeds lazily" unless Quickdraw::Seed::LAZY

		Quickdraw::Seed.later(1234)

		Random.new_seed
		Random.urandom(4)
		Random.new(1).rand
		[1, 2, 3].sum

		assert_equal Quickdraw::Seed.pending, 1234
	end

	test "seeds once, however many threads read at once" do
		skip "Only CRuby seeds lazily" unless Quickdraw::Seed::LAZY

		expected = seeded(1234) { Array.new(200) { rand } }.sort

		Quickdraw::Seed.later(1234)
		go = Thread::Queue.new

		threads = Array.new(8) do
			Thread.new do
				go.pop
				Array.new(25) { rand }
			end
		end

		go.close
		assert_equal threads.flat_map(&:value).sort, expected
	end

	test "seeds in a signal handler" do
		skip "Only CRuby seeds lazily" unless Quickdraw::Seed::LAZY
		skip "Needs USR2" unless Signal.list.key?("USR2")

		expected = seeded(1234) { rand }
		read = Thread::Queue.new
		previous = trap("USR2") { read << rand }
		defer { trap("USR2", previous) }

		Quickdraw::Seed.later(1234)
		Process.kill("USR2", Process.pid)
		assert_equal read.pop(timeout: 5), expected
	end

	test "leaves a fork with the seed Ruby gave it" do
		skip "Needs fork" unless Process.respond_to?(:fork)

		expected = seeded(1234) { rand }
		Quickdraw::Seed.later(1234)
		reader, writer = IO.pipe

		pid = fork do
			writer.write(rand.to_s)
			exit!(0)
		end

		writer.close
		Process.wait(pid)

		refute_equal reader.read, expected.to_s
		assert_equal rand, expected
	ensure
		reader&.close
	end

	test "leaves a daemon with the seed Ruby gave it" do
		skip "Needs fork" unless Process.respond_to?(:fork)

		expected = seeded(1234) { rand }
		reader, writer = IO.pipe

		pid = fork do
			Quickdraw::Seed.later(1234)
			Process.daemon(true, true)
			writer.write(rand.to_s)
			exit!(0)
		end

		writer.close
		Process.wait(pid)

		refute_equal reader.read, expected.to_s
	ensure
		reader&.close
	end

	test "leaves another Ractor's generator alone" do
		skip "Needs Ractors that can return a value" unless Quickdraw::Seed::LAZY && Ractor.method_defined?(:value)

		expected = seeded(1234) { rand }
		Quickdraw::Seed.later(1234)
		experimental, Warning[:experimental] = Warning[:experimental], false
		ractor = Ractor.new { rand }
		value = ractor.value
		ractor.join
		Warning[:experimental] = experimental

		refute_equal value, expected
		assert_equal Quickdraw::Seed.pending, 1234
		assert_equal rand, expected
	end
end
