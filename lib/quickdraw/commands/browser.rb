# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "openssl"

# `browser install [BROWSER …]` installs Playwright for browser tests: its
# playwright-core package from npm, unless the project has its own, then the
# browsers through it, config.browser's by default. Tests never download.
class Quickdraw::Commands::Browser
	include Quickdraw::Commands::Output

	NPM = "https://registry.npmjs.org"
	BROWSERS = ["chromium", "firefox", "webkit"].freeze

	class Failure < StandardError; end

	def initialize(args, io: $stdout)
		@args = args
		@io = io
	end

	def call
		command, *browsers = @args

		unless command == "install" && browsers.all? { |browser| browser in "chromium" | "firefox" | "webkit" }
			warn "Usage: #{Quickdraw::Reporters.command} browser install [#{BROWSERS.join('|')} …]"
			return 2
		end

		settings = configured || {}
		browsers = settings.fetch(:browsers, ["chromium"]) if browsers.empty?
		playwright = Quickdraw::Browser::Executables.playwright || install_playwright
		check_node(playwright)
		install_browsers(playwright, browsers, headless_shell: browsers == ["chromium"] && Quickdraw::Browser::Executables.headless_shell?(settings))
		0
	rescue Failure => error
		@io.puts "#{red('✗')} #{error.message}"
		1
	end

	# config.browser's options, from config booted in a fork, or nil.
	private def configured
		path = Quickdraw::Loader::CONFIG_PATH
		return unless File.exist?(path)

		settings = Quickdraw.isolate do
			require File.expand_path(path)
			Quickdraw::Browser.settings
		rescue Exception => error
			"#{error.class}: #{error.message}"
		end

		raise Failure, "#{path} fails to boot: #{Quickdraw.utf8(settings).lines.first.chomp}" if String === settings

		settings
	end

	private def check_node(playwright)
		required = Quickdraw::Browser::Executables.required_node(playwright)
		node = Quickdraw::Browser::Executables.node_version
		return if node && node.to_i >= required

		raise Failure, "Playwright runs on Node #{required} or later, #{node ? "but this is Node #{node}" : 'which isn’t installed'}. Install it, or set QUICKDRAW_NODE to it."
	end

	# playwright-core from npm, checked against npm's hash and unpacked in Ruby.
	private def install_playwright
		version = Quickdraw::Browser::Executables::PLAYWRIGHT_VERSION
		metadata = JSON.parse(fetch("#{NPM}/playwright-core/#{version}"))
		target = File.dirname(Quickdraw::Browser::Executables.installed_playwright)

		staging(target) do |directory|
			archive = File.join(directory, "playwright-core.tgz")
			download(metadata.dig("dist", "tarball"), archive, "Playwright #{version}")
			verify(archive, metadata.dig("dist", "integrity"))
			untar(archive, directory)
			File.delete(archive)
		end

		@io.puts "#{green('✓')} Installed Playwright #{version} in #{target}"
		Quickdraw::Browser::Executables.installed_playwright
	end

	# With Playwright's own installer, which skips what's installed already.
	private def install_browsers(playwright, browsers, headless_shell:)
		version = Quickdraw::Browser::Executables.playwright_version(playwright)
		@io.puts "Installing #{browsers.join(', ')} for Playwright #{version} (#{playwright})…"
		success = system(Quickdraw::Browser::Executables.node, File.join(playwright, "cli.js"), "install", *("--only-shell" if headless_shell), *browsers)
		raise Failure, "Playwright couldn’t install #{browsers.join(', ')}. If you’re offline, run this again once you’re online." unless success

		@io.puts "#{green('✓')} #{browsers.join(', ')} #{browsers.one? ? 'is' : 'are'} installed for Playwright #{version}."
	end

	# Fills a directory beside `target` in the block, then puts it in place, so
	# a failed install leaves nothing half done. If another install put one
	# there meanwhile, that one stays.
	private def staging(target)
		FileUtils.mkdir_p(File.dirname(target))
		directory = "#{target}.#{Process.pid}.partial"
		FileUtils.rm_rf(directory)
		FileUtils.mkdir_p(directory)
		yield directory

		begin
			File.rename(directory, target)
		rescue Errno::EEXIST, Errno::ENOTEMPTY
			nil
		end
	ensure
		FileUtils.rm_rf(directory) if directory
	end

	private def download(url, path, name)
		@io.puts "Downloading #{name}…"
		File.open(path, "wb") { |file| fetch(url) { |chunk| file.write(chunk) } }
	end

	# The body at `url`, following redirects, or with a block, each chunk of it.
	private def fetch(url, redirects: 5, &block)
		uri = URI(url)

		Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 15, read_timeout: 60) do |http|
			http.request_get(uri) do |response|
				case response
				in Net::HTTPSuccess
					return block ? response.read_body(&block) : response.body
				in Net::HTTPRedirection if redirects > 0
					location = response["location"] or raise Failure, "Couldn’t download #{url}: #{response.code} #{response.message} without a Location."
					target = URI.join(url, location)
					raise Failure, "Couldn’t download #{url}: it redirects to #{target}, which isn’t HTTPS." if uri.scheme == "https" && target.scheme != "https"

					return fetch(target.to_s, redirects: redirects - 1, &block)
				else
					raise Failure, "Couldn’t download #{url}: #{response.code} #{response.message}."
				end
			end
		end
	rescue SocketError, SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => error
		raise Failure, "Couldn’t download #{url} (#{error.message}). Are you offline? Quickdraw only downloads Playwright when you run `#{Quickdraw::Reporters.command} browser install`."
	end

	# Against npm's Subresource Integrity hash.
	private def verify(path, integrity)
		require "digest"
		algorithm, expected = integrity.split("-", 2)
		raise Failure, "npm gave a hash Quickdraw can’t check: #{integrity}." unless algorithm == "sha512"
		raise Failure, "The download of #{File.basename(path)} is corrupt: its hash doesn’t match npm’s." unless Digest::SHA512.file(path).base64digest == expected
	end

	private def untar(path, directory)
		require "rubygems/package"
		require "zlib"

		Zlib::GzipReader.open(path) do |gzip|
			Gem::Package::TarReader.new(gzip).each do |entry|
				destination = File.expand_path(entry.full_name, directory)
				raise Failure, "#{File.basename(path)} has a file outside its directory: #{entry.full_name}." unless destination.start_with?("#{directory}/")

				if entry.directory?
					FileUtils.mkdir_p(destination)
				elsif entry.file?
					FileUtils.mkdir_p(File.dirname(destination))
					File.binwrite(destination, entry.read)
					File.chmod(entry.header.mode & 0o755, destination)
				end
			end
		end
	end
end
