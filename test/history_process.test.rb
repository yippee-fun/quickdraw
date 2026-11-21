# frozen_string_literal: true

class HistoryProcessTest < Quickdraw::Test
	Records = Quickdraw::HistoryProcess::Records

	test "builds records from each file's tests and its results' numbers" do
		tests = [
			{ "class_name" => "ATest", "description" => "adds", "line" => 3 },
			{ "class_name" => "ATest", "description" => nil, "line" => 7, "variant" => "webkit" },
		]
		keys = Quickdraw::History.keys("a.test.rb", tests)
		stats = [0.001, 0.25, 0.002, 0.2, 0.0, 12]
		details = { "failures" => [{ "message" => "no" }], "errors" => [] }

		records = Records.new
		records.receive([:file, "a.test.rb", keys, [3, 7], [1]])
		records.receive([:passed, [0, 1, 2, 4, 5, 6, 0.5, *stats].pack(Records::PASSED)])
		records.receive([:others, [[0, 0, "failed", 0.125, nil, 1, details, 8, 9, 10]]])

		passed, failed = records.to_a

		assert_equal passed.to_h, {
			key: keys[1],
			path: "a.test.rb",
			line: 7,
			described: false,
			status: "passed",
			duration: 0.5,
			stats:,
			assertions: 2,
			details: nil,
			worker: 4,
			slot: 5,
			sequence: 6,
		}

		assert_equal passed.stats.last.class, Integer

		assert_equal failed.to_h, {
			key: keys[0],
			path: "a.test.rb",
			line: 3,
			described: true,
			status: "failed",
			duration: 0.125,
			stats: nil,
			assertions: 1,
			details:,
			worker: 8,
			slot: 9,
			sequence: 10,
		}
	end

	test "a test's key holds its class name, description and variant" do
		tests = [
			{ "class_name" => "ATest", "description" => "adds", "line" => 3 },
			{ "class_name" => "ATest", "description" => nil, "line" => 7, "variant" => "webkit" },
			{ "class_name" => nil, "description" => "line 7", "line" => 9 },
		]
		described, undescribed, anonymous = Quickdraw::History.keys("a.test.rb", tests)

		assert_equal Quickdraw::History.test(described, described: true), ["ATest", "adds", nil]
		assert_equal Quickdraw::History.test(undescribed, described: false), ["ATest", nil, "webkit"]
		assert_equal Quickdraw::History.test(anonymous, described: true), [nil, "line 7", nil]
	end

	test "keys count the tests of a class with the same name" do
		tests = [
			{ "class_name" => "ATest", "description" => "adds", "line" => 3 },
			{ "class_name" => "BTest", "description" => "adds", "line" => 5 },
			{ "class_name" => "ATest", "description" => "adds", "line" => 7 },
			{ "class_name" => "ATest", "description" => "bad \xFF".b, "line" => 9 },
		]

		assert_equal Quickdraw::History.keys("a.test.rb", tests), [
			'["a.test.rb","ATest","adds",1]',
			'["a.test.rb","BTest","adds",1]',
			'["a.test.rb","ATest","adds",2]',
			JSON.generate(["a.test.rb", "ATest", Quickdraw.utf8("bad \xFF".b), 1]),
		]
	end
end
