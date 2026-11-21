# frozen_string_literal: true

class LoaderProcessTest < Quickdraw::Test
	test "gives the channels it was started with, then named pipes, up to its capacity" do
		skip "Named pipes need mkfifo" unless File.respond_to?(:mkfifo)

		directory = File.join(tmpdir, "pipes")
		first = Quickdraw::Channel.new(*IO.pipe)
		loader = Quickdraw::Coordinator::LoaderProcess.new(group: nil, pid: nil, control: nil, report: nil, channels: [first], capacity: 3, directory:)

		assert_equal loader.spares, 3
		assert_equal loader.take_channel, [0, first]
		refute Dir.exist?(directory)

		index, channel = loader.take_channel
		assert_equal index, 1
		assert_equal loader.spares, 1

		# As the loader opens them (see Loader#open_channel).
		down = File.open(File.join(directory, "1.down"), File::RDONLY | File::NONBLOCK, binmode: true)
		up = File.open(File.join(directory, "1.up"), File::WRONLY | File::NONBLOCK, binmode: true)
		worker = Quickdraw::Channel.new(down, up)

		channel.write([:load, "a.test.rb"])
		assert_equal worker.read, [:load, "a.test.rb"]
		worker.write([:ready, 1])
		worker.close
		assert_equal channel.read_available, [[:ready, 1], nil]

		assert_equal loader.take_channel.first, 2
		assert_equal loader.take_channel, nil
	ensure
		[first, channel, worker].compact.each(&:close)
		loader&.close
	end

	test "closing it removes its named pipes" do
		skip "Named pipes need mkfifo" unless File.respond_to?(:mkfifo)

		directory = File.join(tmpdir, "pipes")
		loader = Quickdraw::Coordinator::LoaderProcess.new(group: nil, pid: nil, control: nil, report: nil, channels: [], capacity: 2, directory:)
		_index, channel = loader.take_channel
		assert Dir.exist?(directory)

		loader.close
		refute Dir.exist?(directory)
		assert_equal loader.spares, 0
		assert_equal loader.take_channel, nil
	ensure
		channel&.close
	end

	test "has no more channels when it can't make named pipes" do
		skip "Named pipes need mkfifo" unless File.respond_to?(:mkfifo)

		loader = Quickdraw::Coordinator::LoaderProcess.new(group: nil, pid: nil, control: nil, report: nil, channels: [], capacity: 2, directory: File.join(tmpdir, "missing", "pipes"))
		taken = nil
		warning = capture_warning { taken = loader.take_channel }

		assert_equal taken, nil
		assert_equal loader.spares, 0
		assert_includes warning, "couldn’t open a pipe for another worker"
	end

	private def capture_warning
		original = $stderr
		written = +""
		$stderr = Object.new.tap { |io| io.define_singleton_method(:write) { |*strings| written << strings.join } }
		yield
		written
	ensure
		$stderr = original
	end
end
