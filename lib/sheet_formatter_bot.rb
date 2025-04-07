# frozen_string_literal: true

require 'zeitwerk'

loader = Zeitwerk::Loader.new
loader.push_dir("#{__dir__}/sheet_formatter_bot", namespace: SheetFormatterBot)
loader.setup

require_relative "sheet_formatter_bot/version"

module SheetFormatterBot
  class Error < StandardError; end
  class ConfigError < Error; end
  class SheetsApiError < Error; end
  class CommandParseError < Error; end
end
