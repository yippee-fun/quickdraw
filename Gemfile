# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in quickdraw.gemspec
gemspec

gem "rspec-expectations"
gem "minitest"
gem "nokogiri"

if RUBY_ENGINE == "ruby"
	group :development do
		gem "rubocop"
		gem "covered"
	end
end

# refract 1.1.0 references Prism::MissingNode, which prism 2 removed.
gem "prism", "~> 1.7"
gem "refract"
