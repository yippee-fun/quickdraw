# frozen_string_literal: true

require "phlex"
# Phlex 2.4 checks attribute values against Date without requiring it.
require "date"

# CoverageReport as HTML pages that work from disk: an index with the totals
# and every file, and a page per file with its source marked with what ran.
# Loads Phlex, so only the coordinator may load it, after the run.
module Quickdraw::CoverageHTML
	extend self

	autoload :Layout, "quickdraw/coverage_html/layout"
	autoload :Percentage, "quickdraw/coverage_html/percentage"
	autoload :Total, "quickdraw/coverage_html/total"
	autoload :LineLinks, "quickdraw/coverage_html/line_links"
	autoload :IndexPage, "quickdraw/coverage_html/index_page"
	autoload :FilePage, "quickdraw/coverage_html/file_page"

	def write(report)
		require "fileutils"
		directory = Quickdraw::CoverageReport::DIRECTORY
		files = report.as_json["files"]
		changed = report.changed&.last || {}

		FileUtils.rm_rf(File.join(directory, "files"))
		File.write(Quickdraw::CoverageReport::HTML_PATH, IndexPage.new(report).call)

		report.files.each do |summary|
			page = File.join(directory, page_path(summary.path))
			FileUtils.mkdir_p(File.dirname(page))
			File.write(page, FilePage.new(summary, files.fetch(summary.path), changed: changed.fetch(summary.path, [])).call)
		end
	end

	# A file's page, relative to the index.
	def page_path(path) = "files/#{path}.html"

	# A link to a file's page from the index.
	def href(path)
		require "uri"
		page_path(path.split("/").map { |segment| URI.encode_uri_component(segment) }.join("/"))
	end
end
