# frozen_string_literal: true

module SheetFormatterBot
  module Utils
    # Utility methods for time-related operations
    module TimeUtils
      def greeting_by_hour(hour)
        case hour
        when 5..11
          "Доброе утро"
        when 12..17
          "Добрый день"
        when 18..23
          "Добрый вечер"
        else
          "Здравствуй"
        end
      end

      def parse_game_hour(time_str)
        return nil unless time_str.is_a?(String) && time_str.include?(':')

        hour_str, _minute_str = time_str.split(':', 2)
        return nil unless hour_str =~ /^\d+$/

        hour = hour_str.to_i
        hour
      rescue StandardError => e
        log(:error, "Ошибка при парсинге времени игры '#{time_str}': #{e.message}")
        nil
      end

      # Преобразует строку даты и времени в объект времени с учётом TZInfo
      def parse_game_time(date_str, time_str, timezone)
        day, month, year = date_str.split('.').map(&:to_i)
        hour, min = time_str.split(':').map(&:to_i)
        timezone.local_time(year, month, day, hour, min)
      end

      # Возвращает разницу в часах между двумя объектами времени
      def hours_diff(time1, time2)
        ((time1 - time2) / 3600).round
      end
    end
  end
end
