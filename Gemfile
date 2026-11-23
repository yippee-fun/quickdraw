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
		# For the Rails integration tests on PostgreSQL, which need
		# QUICKDRAW_POSTGRES_URL too.
		gem "pg"
		# For the debugger integration tests.
		gem "debug"
		gem "pry"
		# For the browser integration tests, which serve their app with it.
		gem "puma"
	end
end

gem "refract"
