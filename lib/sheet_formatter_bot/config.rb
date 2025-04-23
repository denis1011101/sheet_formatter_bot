require 'dotenv/load'

module SheetFormatterBot
  module Config
    extend self

    def telegram_token
      fetch_env('TELEGRAM_BOT_TOKEN')
    end

    def spreadsheet_id
      fetch_env('GOOGLE_SHEET_ID')
    end

    def credentials_path
      ENV.fetch('GOOGLE_CREDENTIALS_PATH', './credentials.json')
    end

    def default_sheet_name
      ENV.fetch('DEFAULT_SHEET_NAME', 'Лист1')
    end

    def notification_hours_before
      ENV.fetch('NOTIFICATION_HOURS_BEFORE', '8').to_i
    end

    def tennis_default_time
      ENV.fetch('TENNIS_DEFAULT_TIME', '22:00')
    end

    def notification_check_interval
      ENV.fetch('NOTIFICATION_CHECK_INTERVAL', '900').to_i # 15 минут по умолчанию
    end

    def google_scopes
      [Google::Apis::SheetsV4::AUTH_SPREADSHEETS]
    end

    def timezone
      ENV.fetch('TIMEZONE', 'Asia/Yekaterinburg')
    end

    def morning_notification_hour
      ENV.fetch('MORNING_NOTIFICATION_HOUR', '9').to_i
    end

    def evening_notification_hour
      ENV.fetch('EVENING_NOTIFICATION_HOUR', '20').to_i
    end

    def final_reminder_notification
      ENV.fetch('FINAL_REMINDER_NOTIFICATION', 'true') == 'true'
    end

    def admin_telegram_ids
      # Разделенный запятыми список ID в формате "123456,789012"
      ids_str = ENV.fetch('ADMIN_TELEGRAM_IDS', '')

      # Разбиваем строку и преобразуем в числа
      ids_str.split(',').map(&:strip).map(&:to_i).reject(&:zero?)
    end

    def general_chat_id
      ENV.fetch('GENERAL_CHAT_ID', nil)&.to_i
    end

    def telegram_bot_username
      ENV.fetch('TELEGRAM_BOT_USERNAME', nil)&.strip
    end

    private

    def fetch_env(key)
      ENV.fetch(key) { raise ConfigError, "Не установлена переменная окружения: #{key}" }
    end
  end
end
