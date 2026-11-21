# frozen_string_literal: true

require "rbconfig"

# Optional Rust native extension (ext/quickdraw_ext) for OS primitives, test
# metrics and watchdog deadlines. Falls back cleanly to pure Ruby when not
# compiled, or with QUICKDRAW_NATIVE=0.
module Quickdraw::Native
	FILE = "quickdraw_ext.#{RbConfig::CONFIG['DLEXT']}".freeze

	# Found by hand, since a require that fails searches every installed gem,
	# which takes ~20ms outside Bundler.
	def self.path
		directories = [File.expand_path("../../ext/quickdraw_ext", __dir__), *$LOAD_PATH.map { |path| File.join(path.to_s, "quickdraw") }]
		directories.map { |directory| File.join(directory, FILE) }.find { |file| File.file?(file) }
	end

	# Not an extension built before it had what the worker uses.
	AVAILABLE = ENV["QUICKDRAW_NATIVE"] != "0" && begin
		file = path
		require file if file
		respond_to?(:metrics_start) && respond_to?(:deadline_open)
	rescue LoadError
		false
	end

	def self.available? = AVAILABLE
end
