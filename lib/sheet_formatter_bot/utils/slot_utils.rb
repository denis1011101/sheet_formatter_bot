# frozen_string_literal: true

require_relative "constants"

module SheetFormatterBot
  module Utils
    # Utility methods for handling slots in the SheetFormatterBot
    module SlotUtils
      include SheetFormatterBot::Utils::Constants

      def slot_cancelled?(s)
        s = s.strip.downcase
        IGNORED_SLOT_NAMES.any? { |name| s == name || s.end_with?(name) }
      end

      def format_slots_text(slots)
        return "Все слоты отменены" if slots.all? { |s| s == "Отменен" }

        slots.map.with_index { |slot, idx| slot_line(slot, idx) }.join("\n")
      end

      private

      def slot_line(slot, idx)
        case slot
        when "Отменен"
          "#{idx + 1}. 🚫 Отменен"
        when "Свободно"
          "#{idx + 1}. ⚪ Свободно"
        else
          "#{idx + 1}. #{slot}"
        end
      end
    end
  end
end
