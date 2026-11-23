# frozen_string_literal: true

require "optparse"

class CLIArgumentsTest < Quickdraw::Test
	REJECTED = :rejected

	VALUES = ["4", "0", "-1", "010", "0x1f", "1_0", "+5", "4 ", "", "x", "/a b/i", "json", "junit:report.xml", "json:", ":", "warn", "a.test.rb", "a.test.rb:3", "=4"].freeze
	CLUSTERS = ["--", "-", "-ft", "-tfb", "-fp", "-fp4", "-p4", "-s12", "-nfoo", "-n=foo", "-f-t", "-f=x", "-fq", "-q"].freeze
	ASSIGNMENTS = ["--seed=7", "--name=a=b", "--format=json:out.json", "--retry=-1", "--retry=2", "--capture=false", "--failed=x"].freeze
	NEAR_MISSES = ["--fail", "--for", "--form=json", "--no-failed", "--no-watch", "--nmae", "--NAME", "--no-hist", "---", "--=x"].freeze

	PRINTED = [["--help"], ["-h"], ["--version"], ["-v"], ["-fh"]].freeze
	COMPLETED = [["--fail"], ["--for", "json"], ["--no-failed"], ["--no-hist"]].freeze
	CONVERTED = [["-p", "0x10"], ["-p", "010"], ["-p", "1_0"], ["-p", "+4"]].freeze
	REJECTIONS = [["--nmae", "x"], ["--failed=x"], ["--capture=false"], ["-p"], ["--seed"], ["-p", "abc"], ["-p4x"], ["--seed="], ["--retry", "-1"], ["-f=x"], ["-q"], ["-fq"]].freeze

	def scan(*arguments) = Quickdraw::CLI.new(arguments).__send__(:scan)

	def optparse(*arguments)
		@cli ||= Quickdraw::CLI.new([]).tap do |cli|
			cli.define_singleton_method(:usage_error) { |*| raise OptionParser::InvalidArgument }
		end
		@options ||= {}
		@parser ||= @cli.option_parser(@options)

		@options.replace(@cli.__send__(:defaults))
		operands = @parser.parse(arguments)
		[@options.dup, operands]
	rescue OptionParser::ParseError
		REJECTED
	end

	def switches
		Quickdraw::CLI.new([]).option_parser.top.list.grep(OptionParser::Switch).reject { |switch| switch.long.intersect?(["--help", "--version"]) }
	end

	def names(switch) = switch.short + switch.long.flat_map { |name| name.include?("[no-]") ? [name.sub("[no-]", ""), name.sub("[no-]", "no-")] : [name] }

	def every_name = switches.flat_map { |switch| names(switch) }

	test "reads every switch written plainly, without optparse" do
		assert_equal every_name.size, 41

		switches.each do |switch|
			names(switch).each do |name|
				arguments = switch.arg ? [name, "4"] : [name]
				refute_nil(scan(*arguments)) { arguments.inspect }
			end
		end
	end

	test "reads every switch as optparse does, in each way it can be written" do
		every_name.each do |name|
			VALUES.each do |value|
				[[name], [name, value], ["#{name}=#{value}"], ["#{name}#{value}"], [name, "--", value], [value, name], [name, name, value]].each do |arguments|
					actual = scan(*arguments)
					next if actual.nil?

					assert_equal(actual, optparse(*arguments)) { arguments.inspect }
				end
			end
		end
	end

	test "agrees with optparse about arguments in any combination" do
		random = Random.new(1)
		words = [*every_name, *VALUES, *CLUSTERS, *ASSIGNMENTS, *NEAR_MISSES]
		read = 0

		2_000.times do
			arguments = Array.new(random.rand(1..5)) { words.sample(random:) }
			actual = scan(*arguments)
			next if actual.nil?

			read += 1
			assert_equal(actual, optparse(*arguments)) { arguments.inspect }
		end

		assert_operator read, :>, 300
	end

	test "reads options, clusters, attached values and operands" do
		options, operands = scan("test/models", "-ftp4", "--name=a=b", "-n", "c", "--no-capture", "--format", "json", "--", "-x", "--watch")

		assert_equal operands, ["test/models", "-x", "--watch"]
		match { options => { failed: true, timings: true, processes: 4, names: ["a=b", "c"], capture: false, outputs: [["json", nil]], watch: false, excludes: [] } }
	end

	test "leaves to optparse what it would print, complete, convert or reject" do
		[*PRINTED, *COMPLETED, *CONVERTED, *REJECTIONS].each do |arguments|
			assert_nil(scan(*arguments)) { arguments.inspect }
		end
	end

	test "leaves everything to optparse when POSIXLY_CORRECT stops it reordering" do
		ENV["POSIXLY_CORRECT"] = "1"
		assert_nil scan("a.test.rb", "-f")
	ensure
		ENV.delete("POSIXLY_CORRECT")
	end
end
