# frozen_string_literal: true

# A fuzzed property's corpus: the cases that reached new code, kept as choices
# in .quickdraw/fuzz/<property>/, a file each, named by a hash of the choices,
# in the format of Property's saved cases. Every worker fuzzing the property
# adds to it, and reads the others' new cases as it goes.
class Quickdraw::Fuzz::Corpus
	def self.root = File.join(Quickdraw::ROOT, ".quickdraw/fuzz")

	def self.directory(key)
		File.join(root, Quickdraw.stable_hash(key).to_s(16))
	end

	# The corpus of the property named `key`.
	def self.for(key) = new(directory(key), key:)

	def initialize(directory, key: nil)
		@directory = directory
		@key = key
		@known = {}
	end

	# The cases added since it was last called by any process but this one.
	def unread
		Dir.children(@directory).sort.filter_map do |name|
			# A file still being written has the writer's pid after a dot.
			next if @known.key?(name) || name.include?(".")

			@known[name] = true
			Quickdraw::Property.saved(File.join(@directory, name)).first
		rescue ArgumentError
			nil
		end
	rescue SystemCallError
		[]
	end

	def add(choices)
		name = Quickdraw.stable_hash(choices.join(",")).to_s(16)
		return if @known.key?(name)

		@known[name] = true
		Quickdraw::Property.save(File.join(@directory, name), [choices])
		Quickdraw::Property.label(@directory, @key) if @key
	end

	def size
		Dir.children(@directory).count { |name| !name.include?(".") }
	rescue SystemCallError
		0
	end
end
