# frozen_string_literal: true

require_relative "../support/integration"

class SettingsTest < Quickdraw::Test
	include Integration

	def configured(settings, files)
		project("config/quickdraw.rb" => "Quickdraw.configure do |config|\n#{settings.map { |line| "\tconfig.#{line}\n" }.join}end\n", **files)
	end

	test "config sets leak checks, which the command line overrides", timeout: 20 do
		project = configured(["leaks = :off"], "leaky.test.rb" => "class Leaky < Quickdraw::Test\n\ttest('sets ENV') { ENV['LEAKY'] = '1'; assert true }\nend\n")

		refute_includes project.run("-p", "1", "--no-history").output, "left state behind"
		assert_includes project.run("-p", "1", "--no-history", "--leaks", "warn").output, "left state behind"
	end

	test "config sets retries and allowing flaky tests, which the command line overrides", timeout: 30 do
		flaky = "class Flaky < Quickdraw::Test\n\ttest('fails once') { File.write('runs', 'x', mode: 'a'); assert File.read('runs').size > 1 }\nend\n"
		project = configured(["retries = 0"], "flaky.test.rb" => flaky)

		refute project.run("-p", "1", "--no-history").success?
		assert_equal File.read(File.join(project.directory, "runs")), "x"

		allowed = configured(["allow_flaky = true", "flakes = 'tmp/flakes.json'"], "flaky.test.rb" => flaky)
		assert allowed.run("-p", "1", "--no-history").success?
		assert File.exist?(File.join(allowed.directory, "tmp/flakes.json"))

		File.delete(File.join(allowed.directory, "runs"))
		refute allowed.run("-p", "1", "--no-history", "--no-allow-flaky").success?

		retried = configured(["retries = 0"], "flaky.test.rb" => flaky)
		assert_equal retried.run("-p", "1", "--no-history", "--retry", "1", "--format", "json").events.last["flaky"], 1
	end

	test "config can stop capturing what tests print", timeout: 20 do
		project = configured(["capture = false"], "loud.test.rb" => "class Loud < Quickdraw::Test\n\ttest('prints') { puts 'shown as printed'; assert false }\nend\n")
		result = project.run("-p", "1", "--no-history", "--retry", "0")

		assert_includes result.output, "shown as printed"
		refute_match result.output, /Output\n\s+shown as printed/
	end

	test "says when config sets a setting wrongly", timeout: 20 do
		result = configured(["retries = 9"], "a.test.rb" => "class A < Quickdraw::Test; test('a') { assert true }; end\n").run("--no-history")

		refute result.success?
		assert_includes result.output, "config.retries must be 0 to 3, not 9. --retry N can retry more."
	end
end
