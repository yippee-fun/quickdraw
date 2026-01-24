# frozen_string_literal: true

require "quickdraw/rspec"

# Define a global shared example for this test file
Quickdraw::RSpec.shared_examples "globally defined for isolation test" do
	it "can be used from anywhere" do
		expect(true).to eq(true)
	end
end

Quickdraw::RSpec.describe "shared_examples isolation" do
	describe "shared examples are isolated per context" do
		# Shared examples defined in one context should NOT be accessible
		# from a sibling context

		describe "first context" do
			shared_examples "isolated example" do
				it "works" do
					expect(true).to eq(true)
				end
			end

			it_behaves_like "isolated example"
		end

		describe "second context (sibling)" do
			# This should NOT be able to access "isolated example" from the sibling
			# We test this by verifying our own shared example works
			shared_examples "different isolated example" do
				it "also works" do
					expect(true).to eq(true)
				end
			end

			it_behaves_like "different isolated example"

			it "cannot access sibling shared examples" do
				# Attempt to find shared examples from sibling context
				# This should return nil (not found)
				result = self.class.find_shared_examples("isolated example")
				expect(result).to be_nil
			end
		end
	end

	describe "shared examples are accessible from offspring contexts" do
		shared_examples "parent shared example" do
			it "works from parent" do
				expect(true).to eq(true)
			end
		end

		describe "child context" do
			it_behaves_like "parent shared example"

			describe "grandchild context" do
				it_behaves_like "parent shared example"
			end
		end

		describe "another child context" do
			it_behaves_like "parent shared example"
		end
	end

	describe "nested shared examples" do
		describe "per context" do
			shared_examples "shared examples are nestable" do
				it "works" do
					expect(true).to eq(true)
				end
			end

			it_behaves_like "shared examples are nestable"
		end
	end

	describe "shadowing shared examples" do
		shared_examples "shadowed example" do
			it "uses parent definition" do
				expect(source).to eq("parent")
			end
		end

		describe "child that shadows" do
			shared_examples "shadowed example" do
				it "uses child definition" do
					expect(source).to eq("child")
				end
			end

			it_behaves_like "shadowed example" do
				let(:source) { "child" }
			end
		end

		describe "child that does not shadow" do
			it_behaves_like "shadowed example" do
				let(:source) { "parent" }
			end
		end
	end

	describe "global shared examples are accessible everywhere" do
		describe "deeply nested" do
			describe "very deeply nested" do
				it_behaves_like "globally defined for isolation test"
			end
		end
	end
end
