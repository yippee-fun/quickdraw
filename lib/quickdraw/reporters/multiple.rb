# frozen_string_literal: true

# Sends every event to each of several reporters.
class Quickdraw::Reporters::Multiple
	def initialize(reporters)
		@reporters = reporters
		@fast = reporters.all? { |reporter| reporter.respond_to?(:passed_result) }
	end

	def supports_passed_result? = @fast

	def passed_result(path, test, duration, setup, body, teardown, cpu, gc, allocations, assertions)
		@reporters.each { |reporter| reporter.passed_result(path, test, duration, setup, body, teardown, cpu, gc, allocations, assertions) }
	end

	def booting = @reporters.each(&:booting)
	def nothing_to_run(...) = @reporters.each { |reporter| reporter.nothing_to_run(...) }
	def start(...) = @reporters.each { |reporter| reporter.start(...) }
	def result(...) = @reporters.each { |reporter| reporter.result(...) }
	def load_failed(...) = @reporters.each { |reporter| reporter.load_failed(...) }
	def finished_file(...) = @reporters.each { |reporter| reporter.finished_file(...) }
	def shows_loading_output? = @reporters.any?(&:shows_loading_output?)
	def pause = @reporters.each(&:pause)
	def resume = @reporters.each(&:resume)
	def printed(output) = @reporters.select(&:shows_loading_output?).each { |reporter| reporter.printed(output) }
	def finish(...) = @reporters.each { |reporter| reporter.finish(...) }
end
