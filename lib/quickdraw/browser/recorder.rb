# frozen_string_literal: true

# Wraps a browser test's recorder, adding the paths of the page's failure
# artifacts (see Browser.save) to its failures and errors. The block saves
# them, once, and returns their paths, or nil without a page.
class Quickdraw::Browser::Recorder
	def initialize(recorder, &artifacts)
		@recorder = recorder
		@artifacts = artifacts
	end

	def success!(description) = @recorder.success!(description)
	def skip!(reason) = @recorder.skip!(reason)
	def measure(phase, &) = @recorder.measure(phase, &)

	def failure!(failure)
		artifacts = @artifacts.call
		@recorder.failure!(artifacts ? failure.merge("message" => "#{failure['message']}\n\n#{artifacts}") : failure)
	end

	def error!(error)
		artifacts = @artifacts.call
		@recorder.error!(artifacts ? error.merge("details" => [error["details"], artifacts].compact.join("\n\n")) : error)
	end
end
