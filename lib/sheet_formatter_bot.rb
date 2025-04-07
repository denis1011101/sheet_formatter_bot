# frozen_string_literal: true

require 'zeitwerk'

module SheetFormatterBot
  class Error < StandardError; end
  class ConfigError < Error; end
  class SheetsApiError < Error; end
  class CommandParseError < Error; end
end

# Настраиваем Zeitwerk для автозагрузки
loader = Zeitwerk::Loader.for_gem
loader.setup

# Требуем явно version.rb для доступа к VERSION
require_relative "sheet_formatter_bot/version"
