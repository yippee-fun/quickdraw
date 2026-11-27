# frozen_string_literal: true

# The last run's survivors, for `quickdraw mutate --show`: each one's id,
# heading, change, and the tests that ran it. JSON, since a checkout's files
# are untrusted, through a temporary file, so it's never part of one run.
module Quickdraw::Mutation::Survivors
	extend self

	PATH = ".quickdraw/last-mutate.json"

	# Returns whether they were saved.
	def save(survivors)
		require "json"

		begin
			Dir.mkdir(File.dirname(PATH))
		rescue Errno::EEXIST
			nil
		end

		temporary = "#{PATH}.#{Process.pid}"
		File.write(temporary, JSON.generate(survivors.map { |survivor| survivor.transform_values { |value| utf8(value) } }))
		File.rename(temporary, PATH)
		true
	rescue SystemCallError, JSON::GeneratorError => error
		warn "Quickdraw couldn’t write #{PATH} (#{error.message})."
		false
	end

	# A survivor in full, or every survivor a line each with `key` "all".
	# Returns an exit status.
	def show(key, io:)
		require "json"

		survivors = begin
			JSON.parse(File.read(PATH, encoding: Encoding::UTF_8))
		rescue Errno::ENOENT, JSON::ParserError
			nil
		end

		unless survivors
			warn "No mutation run has been recorded here."
			return 1
		end

		if key == "all"
			survivors.each { |survivor| io.puts survivor["heading"] }
			return 0
		end

		matches = survivors.select { |survivor| survivor["id"] == key }

		if matches.empty?
			warn "The last mutation run had no survivor #{key}."
			return 1
		end

		matches.each do |survivor|
			io.puts survivor["heading"]
			survivor["change"].each { |line| io.puts line }
			io.puts "Tests that ran it and passed:"
			survivor["tests"].each { |test| io.puts "- #{test}" }
		end

		0
	end

	private def utf8(value)
		case value
		in String then Quickdraw.utf8(value)
		in Array then value.map { |item| utf8(item) }
		else value
		end
	end
end
