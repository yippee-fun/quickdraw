# frozen_string_literal: true

# Collects coverage in loaders and workers, for --coverage. Each loader starts
# Ruby's Coverage before config loads, and takes what booting covered before
# forking workers, which clears it, so workers report only what they run.
#
# Only the project's own files are kept: not tests, nor installed gems and
# other projects' files. Method keys hold the method's class, which can't
# cross to the coordinator, so they hold its name instead.
module Quickdraw::CoverageCollector
	extend self

	# Paths, relative to the project, that aren't the project's own code.
	EXCLUDED = %r{\A(?:test|tests|spec|specs|vendor|node_modules|tmp|\.bundle)/|\.test\.rb\z}

	# Quickdraw's own files, wherever it's installed.
	QUICKDRAW = ["#{Quickdraw::LIB}/", "#{File.expand_path('../exe', Quickdraw::LIB)}/"].freeze

	# The project is the directory it starts in, before config can change it.
	def start
		require "coverage"
		@root = "#{Dir.pwd}/"
		::Coverage.start(lines: true, branches: true, methods: true)
	end

	# Coverage since it started or was last taken, as { path => { "lines" =>,
	# "branches" =>, "methods" => } }, with paths relative to the project.
	def take
		::Coverage.result(stop: false, clear: true).each_with_object({}) do |(path, data), files|
			# A file loaded by a relative path has a relative key.
			path = File.expand_path(path, @root)
			next if !path.start_with?(@root) || path.start_with?(*QUICKDRAW)

			relative = path.delete_prefix(@root)
			next if EXCLUDED.match?(relative) || relative == Quickdraw::Loader::CONFIG_PATH

			files[relative] = {
				"lines" => data[:lines],
				"branches" => data[:branches],
				"methods" => data[:methods]&.to_h { |(owner, name, *location), count| [[owner_name(owner), name.to_s, *location], count] },
			}
		end
	end

	# Without the anonymous module each test file is loaded in.
	private def owner_name(owner)
		Quickdraw.utf8(Quickdraw.plain_string(owner.inspect)).gsub(/#<Module:0x\h+>::/, "")
	end
end
