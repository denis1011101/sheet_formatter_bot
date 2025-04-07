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

    def google_scopes
      [Google::Apis::SheetsV4::AUTH_SPREADSHEETS]
    end

    private

    def fetch_env(key)
      ENV.fetch(key) { raise ConfigError, "Не установлена переменная окружения: #{key}" }
    end
  end
end

