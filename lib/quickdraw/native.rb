# frozen_string_literal: true

# Optional Rust native extension (ext/quickdraw_ext) for OS primitives and fast
# clock snapshots. Falls back cleanly to pure Ruby when not compiled.
module Quickdraw::Native
	AVAILABLE = begin
		require "quickdraw/quickdraw_ext"
		true
	rescue LoadError
		begin
			require File.expand_path("../../ext/quickdraw_ext/quickdraw_ext", __dir__)
			true
		rescue LoadError
			false
		end
	end

	def self.available? = AVAILABLE
end
