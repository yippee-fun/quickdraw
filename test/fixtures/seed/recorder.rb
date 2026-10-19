# frozen_string_literal: true

class SeedRecorderTest < Quickdraw::Test
	20.times do |i|
		test "test #{i}" do
			File.open(ENV.fetch("SEED_LOG"), "a") do |log|
				log.puts [Process.pid, i, seed, rand(1_000_000)].join(" ")
			end

			assert true
		end
	end
end
