# frozen_string_literal: true

class Quickdraw::Configuration
	DEFAULT_PROCESSES = Quickdraw::Platform.supports_forking? ? Quickdraw::Platform.non_blocking_cores : 1

	def initialize
		@failure_symbol = "\e[31m⨯\e[0m"
		@success_symbol = "\e[32m∘\e[0m"
		@processes = DEFAULT_PROCESSES
		@success_emoji = %w[💃 🕺 🎉 🎊 💪 👏 🙌 ✨ 🥳 🎈 🌈 🎯 🏆]
		@before_forking_callbacks = []
		@after_forking_callbacks = []
	end

	attr_accessor :failure_symbol
	attr_accessor :processes
	attr_accessor :success_emoji
	attr_accessor :success_symbol

	attr_reader :before_forking_callbacks
	attr_reader :after_forking_callbacks

	def before_forking(&block)
		@before_forking_callbacks << block
	end

	def after_forking(&block)
		@after_forking_callbacks << block
	end
end
