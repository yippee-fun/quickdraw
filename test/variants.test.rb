# frozen_string_literal: true

class VariantsTest < Quickdraw::Test
	test "config.browser with browsers: has a group for each, with the browser as its variant" do
		skip "Variants need fork" unless Process.respond_to?(:fork)

		config = Quickdraw::Configuration.new
		config.browser("test/system/**/*.test.rb", browsers: [:chromium, :webkit]) { :app }

		assert_equal config.groups.map { |group| [group.name, group.patterns, group.cores, group.variant] }, [
			["browser:chromium", ["test/system/**/*.test.rb"], 2, "chromium"],
			["browser:webkit", ["test/system/**/*.test.rb"], 2, "webkit"],
		]
	end

	test "config.browser with browser: has one group, with no variant" do
		config = Quickdraw::Configuration.new
		config.browser("test/system/**/*.test.rb", browser: :webkit) { :app }

		assert_equal config.groups.map { |group| [group.name, group.variant] }, [["browser", nil]]
	end

	test "config.browser's groups are browser groups, left out of plain runs unless by_default: true" do
		config = Quickdraw::Configuration.new
		config.group(:models, "test/models/**/*.test.rb")
		config.browser("test/system/**/*.test.rb") { :app }

		assert_equal config.groups.map { |group| [group.name, group.browser] }, [["models", false], ["browser", true]]
		assert_equal config.settings, { browser_by_default: false }

		config = Quickdraw::Configuration.new
		config.browser("test/system/**/*.test.rb", by_default: true) { :app }
		assert_equal config.settings, { browser_by_default: true }

		error = assert_raises(ArgumentError) { Quickdraw::Configuration.new.browser("test/**/*.test.rb", by_default: nil) }
		assert_equal error.message, "config.browser’s by_default must be true or false, not nil."

		error = assert_raises(ArgumentError) { Quickdraw::Configuration.new.group(:system, "test/**/*.test.rb", browser: "yes") }
		assert_equal error.message, "The system group’s browser must be true or false, not \"yes\"."
	end

	test "config.browser takes browser: or browsers:, each a browser once" do
		skip "Variants need fork" unless Process.respond_to?(:fork)

		error = assert_raises(ArgumentError) { Quickdraw::Configuration.new.browser("test/**/*.test.rb", browser: :chromium, browsers: [:webkit]) }
		assert_equal error.message, "config.browser takes browser: or browsers:, not both."

		error = assert_raises(ArgumentError) { Quickdraw::Configuration.new.browser("test/**/*.test.rb", browsers: [:webkit, :webkit]) }
		assert_equal error.message, "config.browser’s browsers: has webkit twice."

		error = assert_raises(ArgumentError) { Quickdraw::Configuration.new.browser("test/**/*.test.rb", browsers: [:safari]) }
		assert_equal error.message, "config.browser’s browsers must be chromium, firefox or webkit, not safari."

		config = Quickdraw::Configuration.new
		config.browser("test/a/**/*.test.rb", browsers: [:chromium])
		error = assert_raises(ArgumentError) { config.browser("test/b/**/*.test.rb", browsers: [:webkit]) }
		assert_equal error.message, "config.browser can only be called once. Give it every pattern, and browsers: for several browsers."
	end

	test "a test's name and history key have its variant" do
		test = { "class_name" => "SignupTest", "description" => "signs up", "line" => 3 }
		firefox = test.merge("variant" => "firefox")

		assert_equal Quickdraw::Filter.name_of(firefox), "SignupTest › signs up [firefox]"
		assert_equal Quickdraw::Filter.name_of(test), "SignupTest › signs up"

		keys = [test, firefox, test.merge("variant" => "webkit")].map { |it| Quickdraw::History.keys("a.test.rb", [it]).first }
		assert_equal keys.uniq.size, 3
		assert_equal keys.first, '["a.test.rb","SignupTest","signs up",1]'
	end
end
