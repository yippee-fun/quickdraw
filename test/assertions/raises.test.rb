# frozen_string_literal: true

class RaisesTest < Quickdraw::Test
	test "#assert_raises when raising the wrong argument error" do
		assert_test(failures: 1) do
			assert_raises(ArgumentError) do
				raise "Test"
			end
		end
	end

	test "#assert_raises when nothing is raised" do
		assert_test(failures: 1) do
			assert_raises(ArgumentError) do
				"no-op"
			end
		end
	end

	test "#assert_raises when the correct error is raised" do
		assert_test(passes: 1) do
			assert_raises(ArgumentError) do
				raise ArgumentError
			end
		end
	end

	test "#refute_raises when nothing is raised" do
		assert_test(passes: 1) do
			refute_raises do
				"no-op"
			end
		end
	end

	test "#refute_raises when an error is raised" do
		assert_test(failures: 1) do
			refute_raises do
				raise "Test"
			end
		end
	end
end
