# lib/sheet_formatter_bot/telegram_bot.rb
require 'telegram/bot'

module SheetFormatterBot
  class TelegramBot
    attr_reader :token, :sheets_formatter, :bot_instance

    def initialize(token: Config.telegram_token, sheets_formatter: SheetsFormatter.new)
      @token = token
      @sheets_formatter = sheets_formatter
      @bot_instance = nil # Инициализируется в run
      log(:info, "TelegramBot инициализирован.")
    end

    def run
      log(:info, "Запуск Telegram бота...")
      Telegram::Bot::Client.run(token) do |bot|
        @bot_instance = bot # Сохраняем экземпляр клиента API
        log(:info, "Бот успешно подключился к Telegram.")
        listen(bot)
      end
    rescue Telegram::Bot::Exceptions::ResponseError => e
      log(:error, "Критическая ошибка Telegram API при запуске: #{e.message} (Код: #{e.error_code}). Завершение работы.")
      exit(1) # Выход, если не удалось подключиться
    rescue StandardError => e
      log(:error, "Критическая ошибка при запуске бота: #{e.message}\n#{e.backtrace.join("\n")}")
      exit(1)
    end

    private

    def listen(bot)
        bot.listen do |message|
          # Обрабатываем только текстовые сообщения
          next unless message.is_a?(Telegram::Bot::Types::Message) && message.text

          log_incoming(message)

          begin
            # Передаем управление парсеру команд
            command_found = CommandParser.dispatch(message, self)
            handle_unknown_command(message) unless command_found
          rescue StandardError => e
              # Ловим ошибки, возникшие при обработке команды
              log(:error, "Ошибка обработки сообщения #{message.message_id} от #{message.from.id}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
              send_error_message(message.chat.id, "Произошла внутренняя ошибка при обработке вашего запроса.")
          end
        end
    end

    # --- Обработчики команд (вызываются из CommandParser) ---

    def handle_start(message, _captures)
      help_message = <<~HELP
        Привет, #{message.from.first_name}! Я бот для форматирования Google Таблиц.
        Работаю с листом: *#{Config.default_sheet_name}* в таблице ID: `#{Config.spreadsheet_id}`

        Доступные команды:
        #{CommandParser.help_text}

        Доступные цвета для фона: #{SheetsFormatter::COLOR_MAP.keys.join(', ')}
      HELP
      send_message(message.chat.id, help_message)
    end

    def handle_format_simple(message, captures)
      range_a1, format_type = captures
      process_formatting(message.chat.id, range_a1, format_type)
    end

    def handle_format_background(message, captures)
      range_a1, color = captures
      process_formatting(message.chat.id, range_a1, :background, color)
    end

    def handle_unknown_command(message)
      send_message(message.chat.id, "Неизвестная команда или неверный формат. Используйте /start для справки.")
    end

    # --- Вспомогательные методы ---

    def process_formatting(chat_id, range_a1, format_type, value = nil)
      range_a1.upcase! # Приводим к верхнему регистру на всякий случай
      sheet_name = Config.default_sheet_name
      begin
        log(:info, "Попытка форматирования: #{chat_id}, #{sheet_name}!#{range_a1}, #{format_type}, #{value}")
        sheets_formatter.apply_format(sheet_name, range_a1, format_type, value)
        send_message(chat_id, "✅ Формат для `#{range_a1}` на листе '#{sheet_name}' успешно изменен!")
      rescue SheetFormatterBot::Error => e # Ловим ошибки SheetsFormatter или ConfigError
        log(:warn, "Ошибка форматирования для #{chat_id}: #{e.message}")
        send_error_message(chat_id, "⚠️ Ошибка: #{e.message}")
      rescue StandardError => e # Ловим другие неожиданные ошибки
        log(:error, "Неожиданная ошибка при форматировании для #{chat_id}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        send_error_message(chat_id, "Произошла внутренняя ошибка сервера при форматировании.")
      end
    end

    def send_message(chat_id, text, **options)
      return unless @bot_instance # Не пытаться отправить, если бот не инициализирован
      log(:debug, "-> Отправка в #{chat_id}: #{text.gsub("\n", ' ')}")
      @bot_instance.api.send_message(chat_id: chat_id, text: text, parse_mode: 'Markdown', **options)
    rescue Telegram::Bot::Exceptions::ResponseError => e
      log_telegram_api_error(e, chat_id)
    end

    def send_error_message(chat_id, text)
        send_message(chat_id, "❗ #{text}")
    end

    def log_incoming(message)
      user = message.from
      user_info = user ? "#{user.first_name} #{user.last_name}".strip + " (@#{user.username}, ID: #{user.id})" : "Unknown User"
      chat_info = "(Chat ID: #{message.chat.id}, Type: #{message.chat.type})"
      log(:info, "<- Получено от #{user_info} в #{chat_info}: '#{message.text}'")
    end

     def log_telegram_api_error(error, chat_id = 'N/A')
        log(:error, "Ошибка Telegram API при отправке в чат #{chat_id}: #{error.message} (Код: #{error.error_code})")
        case error.error_code
        when 400 # Bad Request
            log(:warn, "   -> Возможно, неверный chat_id или ошибка разметки Markdown?")
        when 403 # Forbidden
            log(:warn, "   -> Бот заблокирован пользователем или удален из чата #{chat_id}.")
        when 429 # Too Many Requests
            log(:warn, "   -> Превышены лимиты Telegram API. Нужно замедлиться.")
            sleep(1) # Небольшая пауза
        end
    end

    # Простое логирование в stdout
    def log(level, message)
      puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] [#{level.upcase}] [TelegramBot] #{message}"
    end
  end
end

