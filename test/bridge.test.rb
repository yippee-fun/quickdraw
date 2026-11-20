# frozen_string_literal: true

require "timeout"

class BridgeTest < Quickdraw::Test
	# A Node stand-in that answers each request with its operation: for "slow",
	# half the reply, then the rest a second later; for "ahead" and "stale",
	# with the next request's id and with 0.
	NODE = <<~RUBY
		require "json"
		$stdout.sync = true

		while (line = $stdin.gets)
			request = JSON.parse(line)

			id = case request["op"]
			in "ahead" then request["id"] + 1
			in "stale" then 0
			else request["id"]
			end

			reply = "\#{JSON.generate({ id:, result: request["op"] })}\\n"

			if request["op"] == "slow"
				print reply[0, 5]
				sleep 1
				print reply[5..]
			else
				print reply
			end
		end
	RUBY

	def bridge
		directory = tmpdir
		node = File.join(directory, "node")
		File.write(node, "#!#{RbConfig.ruby}\n#{NODE}")
		File.chmod(0o755, node)

		bridge = Quickdraw::Browser::Bridge.new(node:, playwright: "playwright", settings: {}, log: File.join(directory, "log"))
		defer { bridge.stop }
		bridge
	end

	test "skips the reply to a request an exception stopped waiting for" do
		bridge = self.bridge
		# Once it's started, the half of the slow reply arrives well within the timeout.
		assert_equal bridge.call("started"), "started"

		assert_raises(Timeout::Error) { Timeout.timeout(0.3) { bridge.call("slow") } }
		assert_equal bridge.call("fast"), "fast"
		assert_equal bridge.call("again"), "again"
	end

	test "raises a Browser::Error for a reply to a request it hasn't made" do
		ahead = assert_raises(Quickdraw::Browser::Error) { bridge.call("ahead") }
		stale = assert_raises(Quickdraw::Browser::Error) { bridge.call("stale") }

		assert_equal ahead.message, "Quickdraw’s Node process answered 2, not 1."
		assert_equal stale.message, "Quickdraw’s Node process answered 0, not 1."
	end
end
