# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in quickdraw.gemspec
gemspec

gem "nokogiri"

if RUBY_ENGINE == "ruby"
	group :development do
		gem "rubocop"
		gem "covered"
	end

	group :test do
		gem "railties", "~> 8.1"
		gem "activerecord", "~> 8.1"
		gem "activejob", "~> 8.1"
		gem "actionmailer", "~> 8.1"
	end
end

gem "refract"
