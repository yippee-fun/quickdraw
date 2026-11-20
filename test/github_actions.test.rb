# frozen_string_literal: true

class GitHubActionsTest < Quickdraw::Test
	def annotations(result)
		require "stringio"
		io = StringIO.new
		reporter = Quickdraw::Reporters::GitHubActions.new(io:, summary_path: nil)
		reporter.start(processes: 1, worker_choice: "manual", seed: 1, paths: [])
		reporter.result("test/user.test.rb", { "description" => "greets", "class_name" => "UserTest", "line" => 3 }, result)
		reporter.finish(Quickdraw::Outcome.new)
		io.string
	end

	test "shows a failure's context under its message, indented like the rest" do
		failure = { "message" => "Expected 1", "path" => "test/user.test.rb", "line" => 4, "context" => "user: alice\nrole: admin" }

		assert_equal annotations("failures" => [failure], "errors" => []),
			"::error file=test/user.test.rb,line=4,title=UserTest › greets::UserTest › greets · test/user.test.rb:3%0A  Expected 1%0A  Context:%0A    user: alice%0A    role: admin\n"
	end

	test "shows an error without context as it is" do
		error = { "name" => "RuntimeError", "message" => "boom", "backtrace" => ["test/user.test.rb:5:in 'block'"] }

		assert_equal annotations("failures" => [], "errors" => [error]),
			"::error file=test/user.test.rb,line=5,title=UserTest › greets::UserTest › greets · test/user.test.rb:3%0A  RuntimeError: boom\n"
	end
end
