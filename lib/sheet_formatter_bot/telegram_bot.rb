# lib/sheet_formatter_bot/telegram_bot.rb
require 'telegram/bot'

module SheetFormatterBot
  class TelegramBot
    attr_reader :token, :sheets_formatter, :bot_instance, :user_registry
    attr_accessor :notification_scheduler

    def initialize(token: Config.telegram_token, sheets_formatter: SheetsFormatter.new)
      @token = token
      @sheets_formatter = sheets_formatter
      @bot_instance = nil # Инициализируется в run
      @user_registry = UserRegistry.new
      @notification_scheduler = nil # Будет установлен позже
      log(:info, "TelegramBot инициализирован.")
    end

    def run
      log(:info, "Запуск Telegram бота...")
      Telegram::Bot::Client.run(token) do |bot|
        @bot_instance = bot # Сохраняем экземпляр клиента API

        # Инициализируем планировщик уведомлений
        @notification_scheduler = NotificationScheduler.new(bot: self, sheets_formatter: sheets_formatter)
        @notification_scheduler.start

        # Запускаем отдельный поток для периодического резервного копирования данных
        start_backup_thread

        log(:info, "Бот успешно подключился к Telegram. Планировщик уведомлений запущен.")
        listen(bot)
      end
    rescue Telegram::Bot::Exceptions::ResponseError => e
      log(:error, "Критическая ошибка Telegram API при запуске: #{e.message} (Код: #{e.error_code}). Завершение работы.")
      exit(1) # Выход, если не удалось подключиться
    rescue StandardError => e
      log(:error, "Критическая ошибка при запуске бота: #{e.message}\n#{e.backtrace.join("\n")}")
      exit(1)
    ensure
      # Останавливаем планировщик уведомлений при завершении работы
      @notification_scheduler&.stop
      @backup_thread&.exit
    end

    private

    def start_backup_thread
      @backup_thread = Thread.new do
        while true
          begin
            sleep(3600) # Делаем резервную копию каждый час
            @user_registry.create_backup
            log(:info, "Создана резервная копия данных пользователей и сопоставлений")
          rescue StandardError => e
            log(:error, "Ошибка при создании резервной копии: #{e.message}")
          end
        end
      end
    end

    def listen(bot)
      bot.listen do |message|
        case message
        when Telegram::Bot::Types::Message
          # Обрабатываем только текстовые сообщения
          next unless message.text

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

        when Telegram::Bot::Types::CallbackQuery
          # Обрабатываем колбэки от inline-кнопок
          log(:info, "Получен callback: #{message.data} от пользователя #{message.from.id}")

          begin
            if message.data.start_with?('attendance:')
              @notification_scheduler.handle_attendance_callback(message)
            else
              log(:warn, "Неизвестный тип callback: #{message.data}")
            end
          rescue StandardError => e
            log(:error, "Ошибка обработки callback #{message.id} от #{message.from.id}: #{e.message}")

            # Отправляем уведомление о проблеме
            bot.api.answer_callback_query(
              callback_query_id: message.id,
              text: "Произошла ошибка при обработке вашего действия."
            )
          end
        end
      end
    end

    # --- Обработчики команд (вызываются из CommandParser) ---

    def handle_start(message, _captures)
      # Регистрируем пользователя
      user = User.from_telegram_user(message.from)
      @user_registry.register_user(user)

      help_message = <<~HELP
        Привет, #{message.from.first_name}! Я бот для уведомлений о теннисных матчах.
        Вы успешно зарегистрированы!

        Работаю с листом: *#{Config.default_sheet_name}* в таблице ID: `#{Config.spreadsheet_id}`

        Доступные команды:
        #{CommandParser.help_text}
      HELP

      send_message(message.chat.id, help_message)
    end

    def handle_name_mapping(message, captures)
      sheet_name, user_identifier = captures

      # Определяем telegram_id пользователя
      target_user = nil

      if user_identifier.start_with?('@')
        # Ищем по @username
        username = user_identifier[1..]
        target_user = @user_registry.find_by_telegram_username(username)
      elsif user_identifier.include?('@')
        # Это email, игнорируем
        send_message(message.chat.id, "⚠️ Использование email не поддерживается. Используйте @username или ID пользователя.")
        return
      else
        # Считаем, что это ID
        telegram_id = user_identifier.to_i
        target_user = @user_registry.find_by_telegram_id(telegram_id)
      end

      unless target_user
        send_message(message.chat.id, "⚠️ Пользователь не найден. Убедитесь, что он зарегистрирован в боте с помощью команды /start.")
        return
      end

      # Сохраняем сопоставление
      @user_registry.map_sheet_name_to_user(sheet_name, target_user.telegram_id)

      send_message(
        message.chat.id,
        "✅ Успешно! Имя `#{sheet_name}` в таблице теперь сопоставлено с пользователем #{target_user.display_name}"
      )

      # Создаем резервную копию после изменения данных
      @user_registry.create_backup
    end

    def handle_set_sheet_name(message, captures)
      sheet_name = captures[0]
      user = @user_registry.find_by_telegram_id(message.from.id)

      unless user
        # Автоматически регистрируем пользователя, если он еще не зарегистрирован
        user = User.from_telegram_user(message.from)
        @user_registry.register_user(user)
      end

      # Сохраняем имя пользователя в таблице
      @user_registry.map_sheet_name_to_user(sheet_name, user.telegram_id)

      send_message(
        message.chat.id,
        "✅ Успешно! Ваше имя в таблице теперь установлено как `#{sheet_name}`"
      )

      # Создаем резервную копию после изменения данных
      @user_registry.create_backup
    end

    def handle_show_mappings(message, _captures)
      # Получаем всех пользователей с установленными именами в таблице
      users_with_sheet_names = @user_registry.all_users.select { |u| u.sheet_name }

      if users_with_sheet_names.empty?
        send_message(message.chat.id, "Нет сохраненных сопоставлений имен.")
        return
      end

      # Формируем сообщение со списком сопоставлений
      mappings_message = "Текущие сопоставления имен:\n\n"
      users_with_sheet_names.each do |user|
        mappings_message += "`#{user.sheet_name}` -> #{user.username ? "@#{user.username}" : user.full_name} (ID: #{user.telegram_id})\n"
      end

      send_message(message.chat.id, mappings_message)
    end

    def handle_unknown_command(message)
      send_message(message.chat.id, "Неизвестная команда или неверный формат. Используйте /start для справки.")
    end

    def handle_test_notification(message, _captures)
      user = @user_registry.find_by_telegram_id(message.from.id)

      unless user
        # Автоматически регистрируем пользователя, если он еще не зарегистрирован
        user = User.from_telegram_user(message.from)
        @user_registry.register_user(user)
      end

      # Проверяем, есть ли у пользователя соответствующее имя в таблице
      unless user.sheet_name
        send_message(
          message.chat.id,
          "⚠️ Сначала укажите своё имя в таблице с помощью команды `/myname <Имя_в_таблице>`"
        )
        return
      end

      # Отправляем тестовое уведомление
      today_str = Date.today.strftime('%d.%m.%Y')
      @notification_scheduler.send_test_notification(user, today_str)

      send_message(
        message.chat.id,
        "✅ Тестовое уведомление отправлено!"
      )
    end

    # --- Вспомогательные методы ---

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
