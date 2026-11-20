# frozen_string_literal: true

require_relative "lib/quickdraw/version"

Gem::Specification.new do |spec|
	spec.name = "quickdraw"
	spec.version = Quickdraw::VERSION
	spec.authors = ["Joel Drapper"]
	spec.email = ["joel@drapper.me"]
	spec.summary = "A Ruby test framework that uses every core."
	spec.homepage = "https://github.com/joeldrapper/quickdraw"
	spec.license = "MIT"
	spec.required_ruby_version = ">= 3.3"

	spec.metadata = {
		"source_code_uri" => spec.homepage,
		"changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
		"funding_uri" => "https://github.com/sponsors/joeldrapper",
		"rubygems_mfa_required" => "true",
	}

	spec.files = Dir["lib/**/*", "exe/*", "README.md", "CHANGELOG.md", "LICENSE.txt"]
	spec.bindir = "exe"
	spec.executables = ["quickdraw", "qt", "qc"]

	spec.add_dependency "phlex", "~> 2.4"

	if RUBY_ENGINE == "jruby"
		spec.platform = "java"
	else
		spec.add_dependency "sqlite3", ">= 1.6"
	end
end
