# frozen_string_literal: true

class SchedulerTest < Quickdraw::Test
	Plan = Struct.new(:files)

	test "files are worth a worker each to start with, without history" do
		assert_equal scheduler(["a", "b", "c"]).first_workers, 3
		assert_equal scheduler([]).first_workers, 0
	end

	test "a file that history expects to take long enough to share is worth more" do
		plan = Plan.new({ "a" => [40, 0.26, 0.01], "b" => [3, 0.004, 0.002] })

		assert_equal scheduler(["a", "b", "c"], plan:).first_workers, 5 + 1 + 1
	end

	test "so is one whose group's files are expected to" do
		groups = [[:browser, ["browser/**"], nil, 2, 0.5, true, nil]]

		assert_equal scheduler([["a", :browser], "b"], groups:).first_workers, 10 + 1
	end

	private def scheduler(files, plan: nil, groups: [])
		unloaded = files.map { |path, group| ["/project/#{path}", path, group] }
		Quickdraw::Coordinator::Scheduler.new(groups:, plan:, core_budget: 4, unloaded:, files: {}, workers: {}, leaving: {}, loaders: {}, retries: nil)
	end
end
