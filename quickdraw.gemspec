# frozen_string_literal: true

require_relative "lib/quickdraw/version"

Gem::Specification.new do |spec|
	spec.name = "quickdraw"
	spec.version = Quickdraw::VERSION
	spec.authors = ["Joel Drapper"]
	spec.email = ["joel@drapper.me"]

	spec.summary = "Experimental test framework"
	spec.description = "Experimental test framework"
	spec.homepage = "https://github.com/joeldrapper/quickdraw"
	spec.license = "MIT"
	spec.required_ruby_version = ">= 3.1"

	spec.metadata["homepage_uri"] = spec.homepage
	spec.metadata["source_code_uri"] = "https://github.com/joeldrapper/quickdraw"
	spec.metadata["changelog_uri"] = "https://github.com/joeldrapper/quickdraw"
	spec.metadata["funding_uri"] = "https://github.com/sponsors/joeldrapper"

	# Specify which files should be added to the gem when it is released.
	# The `git ls-files -z` loads the files in the RubyGem that have been added into git.
	spec.files = Dir.chdir(__dir__) do
		`git ls-files -z`.split("\x0").reject do |f|
			(f == __FILE__) || f.match(%r{\A(?:(?:bin|test|spec|features)/|\.(?:git|circleci)|appveyor)})
		end
	end
	spec.bindir = "exe"
	spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
	spec.require_paths = ["lib"]

	# For more information and examples about making a new gem, check out our
	# guide at: https://bundler.io/guides/creating_gem.html
	spec.metadata["rubygems_mfa_required"] = "true"

	spec.add_dependency "listen", "~> 3.10"
end
