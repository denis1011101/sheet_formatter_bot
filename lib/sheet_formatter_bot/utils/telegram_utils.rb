# frozen_string_literal: true

module SheetFormatterBot
  module Utils
    # Utility methods for Telegram-related operations
    module TelegramUtils
      # Экранирует специальные символы Markdown для Telegram
      def escape_markdown(text)
        return "" if text.nil?

        text.to_s.gsub(/([_*\[\]()~`>#+\-=|{}.!])/, '\\\\\\1')
      end
    end
  end
end
