# frozen_string_literal: true

# Sends every event to each of several reporters.
class Quickdraw::Reporters::Multiple
	def initialize(reporters)
		@reporters = reporters
	end

	def start(...) = @reporters.each { |reporter| reporter.start(...) }
	def result(...) = @reporters.each { |reporter| reporter.result(...) }
	def load_failed(...) = @reporters.each { |reporter| reporter.load_failed(...) }
	def tick(progress) = @reporters.each { |reporter| reporter.tick(progress) }
	def live? = @reporters.any?(&:live?)
	def printed(output) = @reporters.select(&:live?).each { |reporter| reporter.printed(output) }
	def finish(...) = @reporters.each { |reporter| reporter.finish(...) }
end
