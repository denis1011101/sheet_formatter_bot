# frozen_string_literal: true

module SheetFormatterBot
  module Utils
    # Utility methods for handling slots in the SheetFormatterBot
    module SlotUtils
      IGNORED_SLOT_NAMES = [
        "один корт", "два корта", "три корта", "четыре корта", "корты", "бронь", "бронь корта", "бронь кортов"
      ].freeze

      def slot_cancelled?(s)
        s = s.strip.downcase
        s == "отменен" ||
          s == "отменён" ||
          s == "отмена" ||
          s.end_with?("отменен") ||
          s.end_with?("отменён") ||
          s.end_with?("отмена")
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
