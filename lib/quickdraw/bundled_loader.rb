# frozen_string_literal: true

# Runs a loader for a group with its own Gemfile, under the bundle in
# BUNDLE_GEMFILE. See Quickdraw::Loader.start.
lib = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(lib)
require "quickdraw"

loader = Quickdraw::Loader.from_settings(IO.new(Integer(ARGV.fetch(0))))

begin
	require "bundler/setup"
rescue Exception => error
	loader.boot_failed(error)
	exit(false)
end

# Bundler removes installed gems outside the bundle from the load path, which
# may include Quickdraw.
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

exit(loader.call)
