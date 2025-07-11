# frozen_string_literal: true

require "telegram/bot"
require "net/http"
require "net/https"
require "timeout"
require_relative "utils/slot_utils"

module SheetFormatterBot
  # Telegram Bot for managing tennis court bookings and notifications
  class TelegramBot
    include SheetFormatterBot::Utils::SlotUtils
    include SheetFormatterBot::Utils::SlotUtils

    attr_reader :token, :sheets_formatter, :bot_instance, :user_registry
    attr_accessor :notification_scheduler

    def initialize(token: Config.telegram_token, sheets_formatter: SheetsFormatter.new, user_registry: nil, notification_scheduler: nil)
      @token = token
      @sheets_formatter = sheets_formatter
      @bot_instance = nil # Инициализируется в run
      @user_registry = user_registry || UserRegistry.new
      @notification_scheduler = notification_scheduler # Будет установлен позже если nil
      @user_states = {} # Хранит состояние каждого пользователя в процессе регистрации
      @pinned_menu_cache = {} # chat_id => last_check_time
      log(:info, "TelegramBot инициализирован.")
    end

    def run
      lock_file = File.join(Dir.pwd, ".bot_running.lock")

      if File.exist?(lock_file)
        if process_still_running?(lock_file)
          log(:error, "Бот уже запущен. Если вы уверены, что это не так, удалите файл .bot_running.lock")
          exit(1)
        else
          log(:warn, "Найден файл блокировки, но процесс, вероятно, не запущен. Удаляем файл.")
          File.delete(lock_file)
        end
      end

      # Записываем PID в файл блокировки
      File.write(lock_file, Process.pid)

      # Максимальное количество попыток подключения
      max_retries = 10
      retry_count = 0

      begin
        log(:info, "Запуск Telegram бота...")

        begin
          # Попытка подключения к Telegram API
          Telegram::Bot::Client.run(token) do |bot|
            @bot_instance = bot # Сохраняем экземпляр клиента API

            # Полностью очищаем все команды
            bot.api.set_my_commands(commands: [])

            # Инициализируем планировщик уведомлений
            @notification_scheduler = NotificationScheduler.new(bot: self, sheets_formatter: sheets_formatter)
            @notification_scheduler.start

            # Запускаем отдельный поток для периодического резервного копирования данных
            start_backup_thread

            log(:info, "Бот успешно подключился к Telegram. Планировщик уведомлений запущен.")
            listen(bot)
          end
        rescue Telegram::Bot::Exceptions::ResponseError => e
          # Обработка различных типов ошибок
          case e.error_code
          when 429
            # Rate limiting - как сейчас
            if retry_count < max_retries
              retry_after = e.response&.parameters&.fetch("retry_after", 5) || 5
              retry_after = [retry_after.to_i, 5].max
              retry_count += 1
              log(:warn, "Превышены лимиты Telegram API (429). Повторная попытка #{retry_count}/#{max_retries} через #{retry_after} сек.")
              sleep(retry_after)
              retry
            end
          when 502, 503, 504
            # Временные сетевые ошибки
            if retry_count < max_retries
              retry_count += 1
              retry_delay = [retry_count * 10, 60].min  # От 10 до 60 секунд
              log(:warn, "Временная ошибка Telegram API (#{e.error_code}). Повторная попытка #{retry_count}/#{max_retries} через #{retry_delay} сек.")
              sleep(retry_delay)
              retry
            end
          end

          # Если превышено количество попыток или это критическая ошибка
          log(:error, "Критическая ошибка Telegram API: #{e.message} (Код: #{e.error_code})")
          raise
        end
      rescue StandardError => e
        log(:error, "Критическая ошибка при запуске бота: #{e.message}\n#{e.backtrace.join("\n")}")
        exit(1)
      ensure
        # Останавливаем планировщик уведомлений при завершении работы
        @notification_scheduler&.stop
        @backup_thread&.exit

        # Удаляем файл блокировки при завершении работы
        File.delete(lock_file) if File.exist?(lock_file)
      end
    end

    def process_still_running?(lock_file)
      begin
        pid = File.read(lock_file).to_i
        Process.getpgid(pid)  # Проверяем, существует ли процесс
        true
      rescue Errno::ESRCH
        # Процесс не существует
        false
      end
    end

    def handle_change_status_command(message, _captures)
      return unless message.chat.type == "private"

      user_id = message.from.id
      user = @user_registry.find_by_telegram_id(user_id)

      unless user
        # Автоматически регистрируем пользователя, если он еще не зарегистрирован
        user = User.from_telegram_user(message.from)
        @user_registry.register_user(user)
      end

      # Если у пользователя не указано имя в таблице, предлагаем указать
      unless user.sheet_name
        send_message(
          message.chat.id,
          "⚠️ Сначала укажите своё имя в таблице с помощью команды `/myname <Имя_в_таблице>`"
        )
        return
      end

      # Получаем информацию о ближайших играх пользователя
      upcoming_games = find_upcoming_games_for_user(user)

      if upcoming_games.empty?
        send_message(message.chat.id, "📋 У вас нет запланированных игр на ближайшие дни.")
        return
      end

      # Показываем варианты изменения статуса
      show_status_change_options(message.chat.id, upcoming_games)
    end

    def handle_myname_prompt(message, _captures)
      return unless message.chat.type == "private"

      user_id = message.from.id
      user = @user_registry.find_by_telegram_id(user_id)

      unless user
        # Автоматически регистрируем пользователя, если он еще не зарегистрирован
        user = User.from_telegram_user(message.from)
        @user_registry.register_user(user)
      end

      if user.sheet_name
        send_message(
          message.chat.id,
          "Ваше текущее имя в таблице: *#{user.sheet_name}*\n\nДля изменения используйте: `/myname <Новое_имя>`"
        )
      else
        send_message(
          message.chat.id,
          "У вас не указано имя в таблице.\n\nДля установки используйте: `/myname <Ваше_имя_в_таблице>`"
        )
      end
    end

    def handle_show_menu(message, _captures)
      # Получаем информацию о пользователе
      user_id = message.from.id
      user = @user_registry.find_by_telegram_id(user_id)

      # Если пользователь не зарегистрирован, запускаем процедуру регистрации
      unless user
        return handle_start(message, [])
      end

      # Отображаем главное меню
      show_main_menu(message.chat.id)
    end

    def handle_name_mapping(message, captures)
      sheet_name = captures[0].strip # Очищаем от пробелов
      user_identifier = captures[1]

      # Определяем telegram_id пользователя
      target_user = nil

      if user_identifier.start_with?("@")
        # Ищем по @username
        username = user_identifier[1..]
        target_user = @user_registry.find_by_telegram_username(username)
      elsif user_identifier.include?("@")
        # Это email, игнорируем
        send_message(message.chat.id,
                     "⚠️ Использование email не поддерживается. Используйте @username или ID пользователя.")
        return
      else
        # Считаем, что это ID
        telegram_id = user_identifier.to_i
        target_user = @user_registry.find_by_telegram_id(telegram_id)
      end

      unless target_user
        send_message(message.chat.id,
                     "⚠️ Пользователь не найден. Убедитесь, что он зарегистрирован в боте с помощью команды /start.")
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
      # Очищаем имя от лишних пробелов
      sheet_name = captures[0].strip

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
      mappings_message = "Текущие Список имён имен:\n\n"
      users_with_sheet_names.each do |user|
        mappings_message += "`#{user.sheet_name}` -> #{user.username ? "@#{user.username}" : user.full_name} (ID: #{user.telegram_id})\n"
      end

      send_message(message.chat.id, mappings_message, parse_mode: nil)
    end

    def handle_sync_registry(message, _captures)
      log(:info, "Запрашивается синхронизация реестра пользователей")

      # Получаем список администраторов из Config
      admin_ids = Config.admin_telegram_ids

      # Если список пуст, используем ID пользователя, который инициализировал бота
      admin_ids = [85611094] if admin_ids.empty?

      unless admin_ids.include?(message.from.id)
        send_message(message.chat.id, "⛔ Только администратор может выполнять эту команду.")
        return
      end

      # Получаем статистику до синхронизации
      users_count_before = @user_registry.size
      mappings_count_before = @user_registry.instance_variable_get(:@name_mapping).size

      # Выполняем синхронизацию
      @user_registry.synchronize_users_and_mappings

      # Получаем статистику после синхронизации
      users_count_after = @user_registry.size
      mappings_count_after = @user_registry.instance_variable_get(:@name_mapping).size

      # Формируем отчет
      report = <<~REPORT
        📊 Синхронизация выполнена!

        Пользователей: #{users_count_before} -> #{users_count_after}
        Сопоставлений: #{mappings_count_before} -> #{mappings_count_after}

        Пользователи с указанным именем в таблице:
      REPORT

      # Добавляем информацию о пользователях с указанным sheet_name
      users_with_sheet_name = @user_registry.all_users.select { |u| u.sheet_name }
      if users_with_sheet_name.any?
        users_with_sheet_name.each do |user|
          report += "\n- #{user.display_name} -> «#{user.sheet_name}»"
        end
      else
        report += "\nНет пользователей с указанным именем в таблице!"
      end

      send_message(message.chat.id, report, parse_mode: nil)

      # Создаем резервную копию после синхронизации
      @user_registry.create_backup
    end

    def handle_start(message, _captures)
      return unless message.chat.type == "private"

      # Получаем информацию о пользователе
      user_id = message.from.id
      first_name = message.from.first_name

      # Регистрируем пользователя
      user = User.from_telegram_user(message.from)
      @user_registry.register_user(user)

      # Проверяем, есть ли имя пользователя в сопоставлениях (name_mapping.json)
      # Проходимся по всем сопоставлениям имен и ищем запись для текущего пользователя
      user_in_mapping = false
      sheet_name = nil

      @user_registry.instance_variable_get(:@name_mapping).each do |name, mapped_id|
        next unless mapped_id.to_s == user_id.to_s

        user_in_mapping = true
        sheet_name = name
        # Если запись найдена, обновляем sheet_name пользователя
        user.sheet_name = sheet_name
        break
      end

      # Проверяем, указано ли уже имя в таблице
      if user.sheet_name || user_in_mapping
        # Если имя найдено в сопоставлениях или уже установлено в объекте пользователя
        sheet_name ||= user.sheet_name # Используем имя, которое уже в объекте, если не нашли в сопоставлениях

        # Если имя уже есть, показываем приветствие и интерактивные кнопки
        welcome_message = <<~WELCOME
          Привет, #{first_name}! Я бот для уведомлений о теннисных матчах.

          Работаю с листом: *#{Config.default_sheet_name}* в таблице ID: `#{Config.spreadsheet_id}`
        WELCOME

        # Отправляем обычное приветствие
        send_message(message.chat.id, welcome_message)

        # Отправляем и закрепляем меню
        send_and_pin_menu(message.chat.id, user)
      else
        # Если имя еще не указано, запрашиваем его
        welcome_message = <<~WELCOME
          Привет, #{first_name}! Я бот для уведомлений о теннисных матчах.
          Вы успешно зарегистрированы!

          Работаю с листом: *#{Config.default_sheet_name}* в таблице ID: `#{Config.spreadsheet_id}`

          Для правильной работы мне необходимо знать ваше имя из таблицы.
          Как вы записаны в таблице? Пожалуйста, введите ваше имя:
        WELCOME

        send_message(message.chat.id, welcome_message)

        # Переводим пользователя в режим ожидания имени
        @user_states[user_id] = { state: :awaiting_name }
      end
    end

    def send_and_pin_menu(chat_id, user)
      menu_text, keyboard = get_main_menu_content(user)

      pinned_menu_text = <<~MENU
        📌 *ЗАКРЕПЛЕННОЕ МЕНЮ*

        #{menu_text}

        💡 _Это сообщение закреплено для быстрого доступа к функциям бота_
      MENU

      begin
        # Отправляем сообщение с меню
        response = @bot_instance.api.send_message(
          chat_id: chat_id,
          text: pinned_menu_text,
          parse_mode: "Markdown",
          reply_markup: keyboard
        )

        message_id = response.dig("result", "message_id")

        if message_id
          # Через 20 секунд снимаем все закрепления и закрепляем только это сообщение
          Thread.new do
            sleep 20
            begin
              # Снимаем все закрепления (Telegram позволяет только одно закреплённое сообщение)
              @bot_instance.api.unpin_all_chat_messages(chat_id: chat_id)
            rescue StandardError => e
              log(:debug, "Не удалось снять закреплённые сообщения: #{e.message}")
            end

            begin
              @bot_instance.api.pin_chat_message(
                chat_id: chat_id,
                message_id: message_id,
                disable_notification: true
              )
              log(:info, "Меню закреплено в чате #{chat_id} через 20 секунд")
            rescue StandardError => e
              log(:error, "Ошибка при закреплении меню: #{e.message}")
            end
          end
        end
      rescue Telegram::Bot::Exceptions::ResponseError => e
        log(:error, "Ошибка при отправке меню: #{e.message}")
        send_message(chat_id, menu_text, reply_markup: keyboard)
      end
    end

    def update_pinned_menu(chat_id, user)
      begin
        # Открепляем старое сообщение (если есть)
        @bot_instance.api.unpin_chat_message(chat_id: chat_id)
      rescue => e
        log(:debug, "Не удалось открепить старое сообщение: #{e.message}")
      end

      # Отправляем и закрепляем новое меню
      send_and_pin_menu(chat_id, user)
    end

    def handle_test_notification(message, _captures)
      user_id = message.from.id
      user = @user_registry.find_by_telegram_id(user_id)

      # Проверяем, что пользователь зарегистрирован
      unless user
        # Автоматически регистрируем пользователя, если он еще не зарегистрирован
        user = User.from_telegram_user(message.from)
        @user_registry.register_user(user)
      end

      # Если у пользователя не указано имя в таблице, предлагаем указать
      unless user.sheet_name
        send_message(
          message.chat.id,
          "⚠️ Сначала укажите своё имя в таблице с помощью команды `/myname <Имя_в_таблице>`"
        )
        return
      end

      # Отправляем тестовое уведомление
      today_str = Date.today.strftime("%d.%m.%Y")

      if @notification_scheduler.send_test_notification(user, today_str)
        send_message(message.chat.id, "✅ Тестовое уведомление успешно отправлено!")
      else
        send_message(message.chat.id, "❌ Не удалось отправить тестовое уведомление. Возможно, вы заблокировали бота?")
      end
    end

    def handle_cancel_court(message, captures)
      # Только администраторы могут использовать эту команду
      admin_ids = Config.admin_telegram_ids
      unless admin_ids.include?(message.from.id)
        send_message(message.chat.id, "⛔ Только администратор может выполнять эту команду.")
        return
      end

      date_str = captures[0] # формат DD.MM.YYYY
      court_num = captures[1].to_i # номер корта (1-8)

      # Проверяем корректность номера корта
      unless (1..8).include?(court_num)
        send_message(message.chat.id, "❌ Некорректный номер корта. Должен быть от 1 до 8.")
        return
      end

      # Преобразуем номер корта в индекс столбца (индекс с нуля)
      # Корты 1-4 - с тренером (колонки 3-6), корты 5-8 - без тренера (колонки 7-10)
      column_index = court_num <= 4 ? court_num + 2 : court_num + 2

      # Получаем данные таблицы
      spreadsheet_data = @sheets_formatter.get_spreadsheet_data

      # Ищем строку с нужной датой
      row_index = nil
      spreadsheet_data.each_with_index do |row, idx|
        next unless row[0] == date_str
        row_index = idx
        break
      end

      unless row_index
        send_message(message.chat.id, "❌ Дата не найдена в таблице.")
        return
      end

      # Получаем букву колонки для A1 нотации
      col_letter = (column_index + 'A'.ord).chr
      cell_a1 = "#{col_letter}#{row_index + 1}"

      # Устанавливаем "отмена" в выбранную ячейку
      if update_cell_value(Config.default_sheet_name, cell_a1, "отмена")
        # Применяем красный цвет текста
        @sheets_formatter.apply_format(Config.default_sheet_name, cell_a1, :text_color, "red")

        send_message(
          message.chat.id,
          "✅ Корт #{court_num} на дату #{date_str} отмечен как отмененный."
        )

        # Также можно отправить уведомление в общий чат
        if Config.general_chat_id
          send_message(
            Config.general_chat_id,
            "⚠️ *ОТМЕНА КОРТА*\nКорт #{court_num} на дату #{date_str} отменен."
          )
        end
      else
        send_message(
          message.chat.id,
          "❌ Произошла ошибка при отметке корта как отмененного."
        )
      end
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
      @bot_instance = bot
      log(:info, "Начало прослушивания сообщений")

      bot.listen do |message|
        log(:debug, "Получено сообщение типа: #{message.class}")

        begin
          case message
          when Telegram::Bot::Types::Message
            # Обрабатываем только текстовые сообщения
            next unless message.text

            log_incoming(message)

            begin
              # Сначала проверяем, находится ли пользователь в процессе регистрации
              text_handled = handle_text_message(message)

              # Если сообщение не обработано как текст в рамках состояния, проверяем команду
              unless text_handled
                command_found = CommandParser.dispatch(message, self)
                handle_unknown_command(message) unless command_found
              end
            rescue StandardError => e
              # Ловим ошибки, возникшие при обработке сообщения
              log(:error,
                  "Ошибка обработки сообщения #{message.message_id} от #{message.from.id}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
              send_error_message(message.chat.id, "Произошла внутренняя ошибка при обработке вашего запроса.")
            end

          when Telegram::Bot::Types::CallbackQuery
            # Обрабатываем колбэки от inline-кнопок
            log(:info, "Получен callback: #{message.data} от пользователя #{message.from.id}")

            begin
              if message.data.start_with?("attendance:")
                @notification_scheduler.handle_attendance_callback(message)
              elsif message.data.start_with?("book:")
                handle_booking_callback(message)
              elsif message.data.start_with?("menu:")
                handle_menu_callback(message)
              elsif message.data.start_with?("admin:")
                handle_admin_callback(message)
              elsif message.data.start_with?("change_status:")
                handle_change_status_callback(message)
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
        rescue StandardError => e
          log(:error, "Критическая ошибка при обработке сообщения: #{e.message}\n#{e.backtrace.join("\n")}")
        end
      end
    rescue Net::TimeoutError, Net::OpenTimeout, Net::ReadTimeout => e
      log(:warn, "Сетевая ошибка при прослушивании: #{e.message}. Переподключение...")
      sleep(5)
      retry
    rescue Telegram::Bot::Exceptions::ResponseError => e
      case e.error_code
      when 502, 503, 504
        log(:warn, "Временная ошибка Telegram API (#{e.error_code}): #{e.message}. Переподключение через 30 сек...")
        sleep(30)
        retry
      else
        log(:error, "Критическая ошибка Telegram API: #{e.message}")
        raise
      end
    end

    def edit_or_send_menu(chat_id, text, keyboard, message_id = nil)
      if message_id
        # Пытаемся отредактировать существующее сообщение
        begin
          @bot_instance.api.edit_message_text(
            chat_id: chat_id,
            message_id: message_id,
            text: text,
            parse_mode: "Markdown",
            reply_markup: keyboard
          )
          return message_id # Возвращаем тот же message_id
        rescue Telegram::Bot::Exceptions::ResponseError => e
          # Если не удалось отредактировать, отправляем новое
          log(:warn, "Не удалось отредактировать сообщение: #{e.message}")
        end
      end

      # Отправляем новое сообщение
      response = @bot_instance.api.send_message(
        chat_id: chat_id,
        text: text,
        parse_mode: "Markdown",
        reply_markup: keyboard
      )
      response.dig('result', 'message_id')
    end

    def get_main_menu_content(user = nil)
      sheet_name = user&.sheet_name || "Не указано"
      sheet_url = "https://docs.google.com/spreadsheets/d/#{Config.spreadsheet_id}/edit"

      text = <<~MENU
        Главное меню:

        Ваше имя в таблице: *#{sheet_name}*

        Выберите действие:
      MENU

      keyboard_buttons = [
        [
          Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "📊 Открыть таблицу",
            url: sheet_url
          )
        ],
        [
          Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "🗓️ Доступные слоты",
            callback_data: "menu:slots"
          )
        ],
        [
          Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "📋 Изменить статус",
            callback_data: "menu:change_status"
          )
        ],
        [
          Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "📝 Изменить имя",
            callback_data: "menu:change_name"
          )
        ],
        [
          Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "👥 Список имён",
            callback_data: "menu:mappings"
          )
        ],
        [
          Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "🧪 Тестовое уведомление",
            callback_data: "menu:test_notification"
          )
        ]
      ]

      # Добавляем админ кнопку если нужно
      if user && Config.admin_telegram_ids.include?(user.telegram_id)
        keyboard_buttons << [
          Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "🔧 Панель администратора",
            callback_data: "menu:admin"
          )
        ]
      end

      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: keyboard_buttons
      )

      [text, keyboard]
    end

    def get_admin_menu_content
      text = <<~MENU
        🔧 *Панель администратора*

        Выберите действие:
      MENU

      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "🔄 Синхронизировать",
              callback_data: "admin:sync"
            )
          ],
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "❌ Отменить корт",
              callback_data: "admin:cancel"
            )
          ],
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "« Вернуться в главное меню",
              callback_data: "menu:back"
            )
          ]
        ]
      )

      [text, keyboard]
    end

    def show_admin_menu(chat_id)
      # Проверяем, является ли пользователь администратором
      admin_ids = Config.admin_telegram_ids
      user_id = chat_id # В private chat, chat_id и user_id совпадают

      unless admin_ids.include?(user_id)
        send_message(chat_id, "⛔ У вас нет прав администратора для доступа к этому меню.")
        return nil
      end

      menu_text = <<~MENU
        🔧 *Панель администратора*

        Выберите действие:
      MENU

      # Создаем клавиатуру с кнопками действий для администратора
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "🔄 Синхронизировать",
              callback_data: "admin:sync"
            )
          ],
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "❌ Отменить корт",
              callback_data: "admin:cancel"
            )
          ],
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "🔗 Сопоставить имя",
              callback_data: "admin:map"
            )
          ],
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "« Вернуться в главное меню",
              callback_data: "menu:back"
            )
          ]
        ]
      )

      send_message(chat_id, menu_text, reply_markup: keyboard)

      true
    end

    def handle_admin_callback(callback_query)
      user_id = callback_query.from.id
      chat_id = callback_query.message.chat.id
      admin_ids = Config.admin_telegram_ids
      unless admin_ids.include?(user_id)
        answer_callback_query(callback_query.id, "У вас нет прав администратора.", true)
        return
      end

      data = callback_query.data

      # Кнопка "Отменить корт" — показываем ближайшие даты
      if data == "admin:cancel"
        answer_callback_query(callback_query.id)
        spreadsheet_data = @sheets_formatter.get_spreadsheet_data
        today = Date.today
        dates = spreadsheet_data.map { |row| row[0] }
                               .select { |d| d =~ /\d{2}\.\d{2}\.\d{4}/ }
                               .uniq
                               .select do |d|
                                 begin
                                   Date.strptime(d, "%d.%m.%Y") >= today
                                 rescue
                                   false
                                 end
                               end
                               .first(7)

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: dates.map { |d|
            [Telegram::Bot::Types::InlineKeyboardButton.new(text: d, callback_data: "admin:cancel_date:#{d}")]
          } + [
            [Telegram::Bot::Types::InlineKeyboardButton.new(text: "🚫 Отменен", callback_data: "admin:cancel_exit")]
          ]
        )
        send_message(chat_id, "Выберите дату для отмены корта:", reply_markup: keyboard)
        return
      end

      # Кнопка "Отмена" — выход в админ-меню
      if data == "admin:cancel_exit"
        answer_callback_query(callback_query.id)
        show_admin_menu(chat_id)
        return
      end

      # Выбор даты — показываем варианты отмены
      if data =~ /^admin:cancel_date:(\d{2}\.\d{2}\.\d{4})$/
        date_str = $1
        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "Отменить все 4 слота с тренером",
                callback_data: "admin:cancel_slots:with_trainer:#{date_str}"
              ),
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "Отменить все 4 слота без тренера",
                callback_data: "admin:cancel_slots:without_trainer:#{date_str}"
              )
            ],
            [
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "🚫 Отменен",
                callback_data: "admin:cancel_exit"
              )
            ]
          ]
        )
        send_message(chat_id, "Выберите какие слоты отменить на дату #{date_str}:", reply_markup: keyboard)
        return
      end

      # Отмена слотов — отмечаем все 4 слота как "отмена"
      if data =~ /^admin:cancel_slots:(with_trainer|without_trainer):(\d{2}\.\d{2}\.\d{4})$/
        type, date_str = $1, $2
        spreadsheet_data = @sheets_formatter.get_spreadsheet_data
        row_index = spreadsheet_data.find_index { |row| row[0] == date_str }
        if row_index.nil?
          send_message(chat_id, "❌ Дата не найдена в таблице.")
          return
        end

        col_range = type == "with_trainer" ? (3..6) : (7..10)
        sheet_name = Config.default_sheet_name

        col_range.each do |col_idx|
          col_letter = (col_idx + 'A'.ord).chr
          cell_a1 = "#{col_letter}#{row_index + 1}"
          update_cell_value(sheet_name, cell_a1, "отмена")
          @sheets_formatter.apply_format(sheet_name, cell_a1, :text_color, "red")
        end

        send_message(chat_id, "✅ Все 4 слота #{type == 'with_trainer' ? 'с тренером' : 'без тренера'} на дату #{date_str} отмечены как отменённые.")
        show_admin_menu(chat_id)
        return
      end

      # Остальные действия (например, sync, map, back) оставьте как есть:
      action = callback_query.data.split(":")[1]
      case action
      when "sync"
        answer_callback_query(callback_query.id, "Выполняю синхронизацию...")

        users_count_before = @user_registry.size
        mappings_count_before = @user_registry.instance_variable_get(:@name_mapping).size

        @user_registry.synchronize_users_and_mappings

        users_count_after = @user_registry.size
        mappings_count_after = @user_registry.instance_variable_get(:@name_mapping).size

        report = <<~REPORT
          📊 Синхронизация выполнена!

          Пользователей: #{users_count_before} -> #{users_count_after}
          Сопоставлений: #{mappings_count_before} -> #{mappings_count_after}

          Пользователи с указанным именем в таблице:
        REPORT

        users_with_sheet_name = @user_registry.all_users.select { |u| u.sheet_name }
        if users_with_sheet_name.any?
          users_with_sheet_name.each do |user|
            report += "\n- #{user.display_name} -> «#{user.sheet_name}»"
          end
        else
          report += "\nНет пользователей с указанным именем в таблице!"
        end

        send_message(chat_id, report, parse_mode: nil)
        @user_registry.create_backup

      when "map"
        answer_callback_query(callback_query.id)
        @user_states[user_id] = { state: :awaiting_map_name }
        send_message(chat_id, "Введите имя в таблице для сопоставления:")

      when "back"
        answer_callback_query(callback_query.id)
        show_main_menu(chat_id)
      end
    end

    def answer_callback_query(callback_query_id, text = nil, show_alert = false)
      return unless @bot_instance

      @bot_instance.api.answer_callback_query(
        callback_query_id: callback_query_id,
        text: text,
        show_alert: show_alert
      )
    rescue Telegram::Bot::Exceptions::ResponseError => e
      log(:error, "Ошибка при ответе на callback query: #{e.message}")
    end

    def handle_menu_callback(callback_query)
      action = callback_query.data.split(":")[1]
      user_id = callback_query.from.id
      chat_id = callback_query.message.chat.id
      message_id = callback_query.message.message_id
      user = @user_registry.find_by_telegram_id(user_id)

      # Проверяем закрепленное меню
      if user
        ensure_pinned_menu(chat_id, user)
      end

      case action
      when "slots"
        @bot_instance.api.answer_callback_query(
          callback_query_id: callback_query.id,
          text: "Загружаю доступные слоты..."
        )

        unless user && user.sheet_name
          # Показываем предупреждение в том же сообщении
          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "📝 Указать имя",
                  callback_data: "menu:change_name"
                )
              ],
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "« Назад",
                  callback_data: "menu:back"
                )
              ]
            ]
          )

          edit_or_send_menu(
            chat_id,
            "⚠️ Сначала укажите своё имя в таблице",
            keyboard,
            message_id
          )
          return
        end

        # Получаем содержимое слотов и показываем в том же сообщении
        slots_content = get_available_slots_content()

        if slots_content
          edit_or_send_menu(
            chat_id,
            slots_content[:text],
            slots_content[:keyboard],
            message_id
          )
        else
          edit_or_send_menu(
            chat_id,
            "К сожалению, не удалось найти предстоящие игры в таблице.",
            Telegram::Bot::Types::InlineKeyboardMarkup.new(
              inline_keyboard: [
                [
                  Telegram::Bot::Types::InlineKeyboardButton.new(
                    text: "« Назад к меню",
                    callback_data: "menu:back"
                  )
                ]
              ]
            ),
            message_id
          )
        end

      when "change_status"
        @bot_instance.api.answer_callback_query(
          callback_query_id: callback_query.id,
          text: "Поиск ближайших игр..."
        )

        unless user && user.sheet_name
          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "📝 Указать имя",
                  callback_data: "menu:change_name"
                )
              ],
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "« Назад",
                  callback_data: "menu:back"
                )
              ]
            ]
          )

          edit_or_send_menu(
            chat_id,
            "⚠️ Сначала укажите своё имя с помощью кнопки 'Изменить имя'",
            keyboard,
            message_id
          )
          return
        end

        # Получаем информацию о ближайших играх пользователя
        upcoming_games = find_upcoming_games_for_user(user)

        if upcoming_games.empty?
          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "« Назад к меню",
                  callback_data: "menu:back"
                )
              ]
            ]
          )

          edit_or_send_menu(
            chat_id,
            "📋 У вас нет запланированных игр на ближайшие дни.",
            keyboard,
            message_id
          )
          return
        end

        status_content = get_status_change_content(upcoming_games)
        edit_or_send_menu(
          chat_id,
          status_content[:text],
          status_content[:keyboard],
          message_id
        )

      when "change_name"
        @user_states[user_id] = { state: :changing_name }

        @bot_instance.api.answer_callback_query(
          callback_query_id: callback_query.id
        )

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "🚫 Отменить",
                callback_data: "menu:back"
              )
            ]
          ]
        )

        edit_or_send_menu(
          chat_id,
          "Пожалуйста, введите новое имя для таблицы:",
          keyboard,
          message_id
        )

      when "mappings"
        @bot_instance.api.answer_callback_query(
          callback_query_id: callback_query.id,
          text: "Загружаю список..."
        )

        users_with_sheet_names = @user_registry.all_users.select { |u| u.sheet_name }

        if users_with_sheet_names.empty?
          mappings_text = "Нет сохраненных сопоставлений имен."
        else
          mappings_text = "Текущие сопоставления имен:\n\n"
          users_with_sheet_names.each do |user|
            mappings_text += "#{user.sheet_name} -> #{user.username ? "@#{user.username}" : user.full_name}\n"
          end
        end

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "« Назад к меню",
                callback_data: "menu:back"
              )
            ]
          ]
        )

        edit_or_send_menu(chat_id, mappings_text, keyboard, message_id)

      when "test_notification"
        @bot_instance.api.answer_callback_query(
          callback_query_id: callback_query.id,
          text: "Отправляю тестовое уведомление..."
        )

        unless user && user.sheet_name
          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "📝 Указать имя",
                  callback_data: "menu:change_name"
                )
              ],
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "« Назад",
                  callback_data: "menu:back"
                )
              ]
            ]
          )

          edit_or_send_menu(
            chat_id,
            "⚠️ Сначала укажите своё имя",
            keyboard,
            message_id
          )
          return
        end

        # Отправляем тестовое уведомление
        today_str = Date.today.strftime("%d.%m.%Y")
        if @notification_scheduler.send_test_notification(user, today_str)
          result_text = "✅ Тестовое уведомление успешно отправлено!"
        else
          result_text = "❌ Не удалось отправить тестовое уведомление. Возможно, вы заблокировали бота?"
        end

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "« Назад к меню",
                callback_data: "menu:back"
              )
            ]
          ]
        )

        edit_or_send_menu(chat_id, result_text, keyboard, message_id)

      when "admin"
        @bot_instance.api.answer_callback_query(
          callback_query_id: callback_query.id,
          text: "Открываю панель администратора..."
        )

        edit_or_send_menu(
          chat_id,
          *get_admin_menu_content(),
          message_id
        )

      when "back"
        @bot_instance.api.answer_callback_query(
          callback_query_id: callback_query.id
        )

        if @user_states[user_id] && @user_states[user_id][:state] == :changing_name
          @user_states.delete(user_id)
        end

        edit_or_send_menu(
          chat_id,
          *get_main_menu_content(user),
          message_id
        )
      end
    end

    def get_status_change_content(games)
      if games.size == 1
        game = games[0]
        text = <<~MESSAGE
          📋 *Изменение статуса участия*

          📅 Дата: *#{game[:date]}*
          🕒 Время: *#{game[:time]}*
          📍 Место: *#{game[:place]}*

          Текущий статус: #{status_text(game[:status])}

          Выберите новый статус участия:
        MESSAGE

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: '✅ Да',
                callback_data: "attendance:yes:#{game[:date]}"
              ),
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: '❌ Нет',
                callback_data: "attendance:no:#{game[:date]}"
              ),
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: '🤔 Не уверен',
                callback_data: "attendance:maybe:#{game[:date]}"
              )
            ],
            [
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "« Назад к меню",
                callback_data: "menu:back"
              )
            ]
          ]
        )
      else
        # Если несколько игр, даем выбрать какую игру изменить
        text = "📋 *Ваши ближайшие игры:*\n\n"

        games.each_with_index do |game, index|
          status_emoji = case game[:status]
                        when "yes" then "✅"
                        when "no" then "❌"
                        when "maybe" then "🤔"
                        else "⚪"
                        end

          text += "#{index + 1}. #{status_emoji} *#{game[:date]}* в #{game[:time]}\n"
        end

        text += "\nВыберите игру для изменения статуса:"

        # Создаем кнопки для выбора игры
        keyboard_buttons = games.map.with_index do |game, index|
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "Игра #{index + 1}: #{game[:date]}",
              callback_data: "change_status:#{game[:date]}:#{game[:status]}"
            )
          ]
        end

        keyboard_buttons << [
          Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "« Назад к меню",
            callback_data: "menu:back"
          )
        ]

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: keyboard_buttons
        )
      end

      {
        text: text,
        keyboard: keyboard
      }
    end

    # Обрабатывает callback для изменения статуса
    def handle_change_status_callback(callback_query)
      _, date_str, current_status = callback_query.data.split(":")
      user_id = callback_query.from.id
      chat_id = callback_query.message.chat.id
      user = @user_registry.find_by_telegram_id(user_id)

      # Находим информацию о выбранной игре
      game = find_game_by_date(date_str)

      unless game
        @bot_instance.api.answer_callback_query(
          callback_query_id: callback_query.id,
          text: "Ошибка: информация о игре не найдена",
          show_alert: true
        )
        return
      end

      show_status_buttons_for_game(chat_id, game.merge(status: current_status))
    end

    def find_game_by_date(date_str)
      spreadsheet_data = @sheets_formatter.get_spreadsheet_data

      spreadsheet_data.each do |row|
        next unless row[0] == date_str

        return {
          date: date_str,
          time: row[1] || Config.tennis_default_time,
          place: row[2] || "обычное место"
        }
      end

      nil
    end

    def find_upcoming_games_for_user(user)
      return [] unless user&.sheet_name

      today = Date.today.strftime("%d.%m.%Y")
      tomorrow = (Date.today + 1).strftime("%d.%m.%Y")
      upcoming_games = []

      # ОПТИМИЗАЦИЯ: Получаем данные только для нужных дат
      target_dates = [today, tomorrow]
      spreadsheet_data = @sheets_formatter.get_spreadsheet_data_for_dates(target_dates)

      # Если специальный метод недоступен, используем обычный
      if spreadsheet_data.empty?
        spreadsheet_data = @sheets_formatter.get_spreadsheet_data
        # Фильтруем только нужные даты
        spreadsheet_data = spreadsheet_data.select { |row| target_dates.include?(row[0]) }
      end

      # Проверяем игры на сегодня и завтра
      spreadsheet_data.each do |row|
        date_str = row[0]
        next unless target_dates.include?(date_str)

        # Проверяем все ячейки, где могут быть записаны игроки (колонки 3-15)
        user_found = false
        row_data = {}

        (3..15).each do |i|
          next if row[i].nil? || row[i].strip.empty?

          if row[i].strip == user.sheet_name
            user_found = true

            # Получаем статус участия
            col_letter = (i + 'A'.ord).chr
            # Используем индекс строки из полной таблицы
            full_data = @sheets_formatter.get_spreadsheet_data
            actual_row_index = full_data.index(row)

            if actual_row_index
              cell_a1 = "#{col_letter}#{actual_row_index + 1}"
              formats = @sheets_formatter.get_cell_formats(Config.default_sheet_name, cell_a1)
              status = "unknown"

              if formats && formats[:text_color]
                status = case formats[:text_color]
                        when "green" then "yes"
                        when "red" then "no"
                        when "yellow" then "maybe"
                        else "unknown"
                        end
              end

              row_data = {
                date: date_str,
                time: row[1] || Config.tennis_default_time,
                place: row[2] || "обычное место",
                status: status
              }
            end

            break
          end
        end

        upcoming_games << row_data if user_found
      end

      upcoming_games
    end

    # Показывает варианты изменения статуса для ближайших игр
    def show_status_change_options(chat_id, games)
      # Если игра только одна, сразу показываем кнопки для изменения статуса
      if games.size == 1
        show_status_buttons_for_game(chat_id, games[0])
        return
      end

      # Если несколько игр, даем выбрать какую игру изменить
      message = "📋 *Ваши ближайшие игры:*\n\n"

      games.each_with_index do |game, index|
        status_emoji = case game[:status]
                      when "yes" then "✅"
                      when "no" then "❌"
                      when "maybe" then "🤔"
                      else "⚪"
                      end

        message += "#{index + 1}. #{status_emoji} *#{game[:date]}* в #{game[:time]}\n"
      end

      message += "\nВыберите игру для изменения статуса:"

      # Создаем кнопки для выбора игры
      keyboard_buttons = games.map.with_index do |game, index|
        [
          Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "Игра #{index + 1}: #{game[:date]}",
            callback_data: "change_status:#{game[:date]}:#{game[:status]}"
          )
        ]
      end

      keyboard_buttons << [
        Telegram::Bot::Types::InlineKeyboardButton.new(
          text: "« Назад к меню",
          callback_data: "menu:back"
        )
      ]

      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: keyboard_buttons
      )

      send_message(chat_id, message, reply_markup: keyboard)
    end

    # Показывает кнопки для изменения статуса конкретной игры
    def show_status_buttons_for_game(chat_id, game)
      date_str = game[:date]
      current_status = game[:status]

      message = <<~MESSAGE
        📋 *Изменение статуса участия*

        📅 Дата: *#{date_str}*
        🕒 Время: *#{game[:time]}*
        📍 Место: *#{game[:place]}*

        Текущий статус: #{status_text(current_status)}

        Выберите новый статус участия:
      MESSAGE

      # Создаем клавиатуру с кнопками для изменения статуса
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: '✅ Да',
              callback_data: "attendance:yes:#{date_str}"
            ),
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: '❌ Нет',
              callback_data: "attendance:no:#{date_str}"
            ),
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: '🤔 Не уверен',
              callback_data: "attendance:maybe:#{date_str}"
            )
          ],
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "« Назад к меню",
              callback_data: "menu:back"
            )
          ]
        ]
      )

      send_message(chat_id, message, reply_markup: keyboard)
    end

    # Форматирует текстовое представление статуса
    def status_text(status)
      case status
      when "yes" then "✅ Вы подтвердили участие"
      when "no" then "❌ Вы отказались от участия"
      when "maybe" then "🤔 Вы не уверены в участии"
      else "⚪ Статус не указан"
      end
    end

    def handle_text_message(message)
      user_id = message.from.id
      text = message.text

      return true unless message.chat.type == "private"

      # Получаем пользователя
      user = @user_registry.find_by_telegram_id(user_id)

      # Проверяем закрепленное меню, если пользователь зарегистрирован
      if user
        ensure_pinned_menu(message.chat.id, user)
      end

      # Проверяем состояние пользователя
      if @user_states[user_id]
        case @user_states[user_id][:state]
        when :awaiting_name
          # Сохраняем имя пользователя при первичной регистрации
          handle_name_input(message, text)
          return true
        when :changing_name
          # Обрабатываем изменение имени
          handle_name_change(message, text)
          return true

        # Добавляем новые состояния для админских действий
        when :awaiting_cancel_date
          # Обрабатываем ввод даты для отмены корта
          if text =~ /^\d{2}\.\d{2}\.\d{4}$/
            @user_states[user_id] = { state: :awaiting_cancel_court, date: text }
            send_message(
              message.chat.id,
              "Теперь введите номер корта (1-8):"
            )
          else
            send_message(
              message.chat.id,
              "⚠️ Некорректный формат даты. Введите дату в формате ДД.ММ.ГГГГ (например, 01.05.2023):"
            )
          end
          return true

        when :awaiting_cancel_court
          # Обрабатываем ввод номера корта
          if text =~ /^[1-8]$/
            date_str = @user_states[user_id][:date]
            court_num = text.to_i

            # Отмечаем корт как отмененный и вызываем существующую логику
            handle_cancel_court(message, [date_str, text])

            # Сбрасываем состояние
            @user_states.delete(user_id)

            # Показываем админ-панель снова
            show_admin_menu(message.chat.id)
          else
            send_message(
              message.chat.id,
              "⚠️ Некорректный номер корта. Введите число от 1 до 8:"
            )
          end
          return true

        when :awaiting_map_name
          # Обрабатываем ввод имени для сопоставления
          sheet_name = text.strip
          @user_states[user_id] = { state: :awaiting_map_user, sheet_name: sheet_name }
          send_message(
            message.chat.id,
            "Теперь введите @username или ID пользователя Telegram:"
          )
          return true

        when :awaiting_map_user
          # Обрабатываем ввод пользователя для сопоставления
          sheet_name = @user_states[user_id][:sheet_name]
          user_identifier = text.strip

          # Вызываем существующую логику сопоставления имени
          handle_name_mapping(message, [sheet_name, user_identifier])

          # Сбрасываем состояние
          @user_states.delete(user_id)

          # Показываем админ-панель снова
          show_admin_menu(message.chat.id)
          return true
        end
      end

      # Если это команда /start, обрабатываем ее несмотря ни на что
      if text.start_with?("/start")
        handle_start(message, [])
        return true
      end

      # Никакое состояние не соответствует полученному сообщению
      false
    end

    def show_main_menu(chat_id, text = "Главное меню:")
      user_id = chat_id # В private chat, chat_id и user_id совпадают
      user = @user_registry.find_by_telegram_id(user_id)

      # Проверяем и обеспечиваем наличие закрепленного меню
      menu_was_pinned = ensure_pinned_menu(chat_id, user)

      # Если меню было только что закреплено, не отправляем дублирующее сообщение
      return if menu_was_pinned && text == "Главное меню:"

      # Добавляем текст к основному меню
      menu_text, keyboard = get_main_menu_content(user)
      final_text = text == "Главное меню:" ? menu_text : "#{text}\n\n#{menu_text}"

      send_message(chat_id, final_text, reply_markup: keyboard)
    end

    def handle_name_change(message, name)
      user_id = message.from.id

      # Удаляем лишние пробелы с обеих сторон имени
      clean_name = name.strip

      # Сохраняем имя в профиле пользователя
      @user_registry.map_sheet_name_to_user(clean_name, user_id)

      # Сбрасываем состояние
      @user_states.delete(user_id)

      # Получаем пользователя для показа обновленного меню
      user = @user_registry.find_by_telegram_id(user_id)

      # Отправляем новое сообщение с главным меню
      success_message = "✅ Ваше имя в таблице изменено на: *#{clean_name}*\n\n"
      menu_text, keyboard = get_main_menu_content(user)

      send_message(message.chat.id, success_message + menu_text, reply_markup: keyboard)

      # Обновляем закрепленное меню
      update_pinned_menu(message.chat.id, user)

      # Создаем резервную копию после изменения данных
      @user_registry.create_backup
    end

    def handle_name_input(message, name)
      user_id = message.from.id

      # Удаляем лишние пробелы с обеих сторон имени
      clean_name = name.strip

      # Сохраняем имя в профиле пользователя
      @user_registry.map_sheet_name_to_user(clean_name, user_id)

      # Переходим к состоянию "зарегистрирован"
      @user_states.delete(user_id)

      # Получаем пользователя для показа обновленного меню
      user = @user_registry.find_by_telegram_id(user_id)

      # Отправляем новое сообщение с главным меню
      success_message = "✅ Отлично! Ваше имя в таблице установлено как: *#{clean_name}*\n\n"
      menu_text, keyboard = get_main_menu_content(user)

      send_message(message.chat.id, success_message + menu_text, reply_markup: keyboard)

       # Отправляем и закрепляем меню
      send_and_pin_menu(message.chat.id, user)

      # Создаем резервную копию после изменения данных
      @user_registry.create_backup
    end

    def get_available_slots_content
      # Получаем данные из таблицы для следующей доступной даты
      spreadsheet_data = @sheets_formatter.get_spreadsheet_data

      # Находим следующую дату тенниса (первую строку после сегодняшнего дня)
      today = Date.today
      next_date_row = nil
      next_date_str = nil

      spreadsheet_data.each_with_index do |row, row_idx|
        next unless row[0] # Пропускаем строки без даты

        begin
          row_date = Date.strptime(row[0], "%d.%m.%Y")
          if row_date >= today
            next_date_row = row
            next_date_str = row[0]
            break
          end
        rescue ArgumentError, TypeError
          # Пропускаем строки с неверным форматом даты
          next
        end
      end

      return nil unless next_date_row

      # Показываем информацию о следующей дате
      time_str = next_date_row[1] || "Время не указано"
      place_str = next_date_row[2] || "Место не указано"

      # Начинаем формировать единое сообщение
      message = <<~INFO
        📅 Следующая игра: *#{next_date_str}*
        🕒 Время: *#{time_str}*
        📍 Место: *#{place_str}*

        Доступные слоты для записи:

      INFO

      # Анализируем слоты с тренером (колонки 3-6)
      slots_with_trainer = []
      for i in 3..6
        slot_name = next_date_row[i]
        clean_name = slot_name.nil? ? nil : slot_name.strip.downcase

        slots_with_trainer << {
          index: i,
          name: if slot_name.nil? || slot_name.strip.empty?
                  nil
                elsif CANCELLED_SLOT_NAMES.include?(clean_name)
                  "Отменен"
                elsif IGNORED_SLOT_NAMES.include?(clean_name)
                  nil
                else
                  slot_name.strip
                end
        }
      end

      # Анализируем основные слоты без тренера (колонки 7-14)
      slots_without_trainer = []
      for i in 7..14
        slot_name = next_date_row[i]
        clean_name = slot_name.nil? ? nil : slot_name.strip.downcase

        slots_without_trainer << {
          index: i,
          name: if slot_name.nil? || slot_name.strip.empty?
                  nil
                elsif CANCELLED_SLOT_NAMES.include?(clean_name)
                  "Отменен"
                elsif IGNORED_SLOT_NAMES.include?(clean_name)
                  nil
                else
                  slot_name.strip
                end
        }
      end

      if slots_without_trainer.first(4).all? { |s| s[:name] == "Отменен" }
        # Отменяем все остальные слоты без тренера (5-8)
        slots_without_trainer.each { |slot| slot[:name] = "Отменен" }
      end

      # Добавляем информацию о слотах с тренером
      message += "👥 *С тренером*:\n"
      slots_with_trainer.each_with_index do |slot, idx|
        if slot[:name]
          if CANCELLED_SLOT_NAMES.include?(slot[:name].downcase)
            message += "#{idx + 1}. 🚫 _Отменен_ ❌\n"
          else
            message += "#{idx + 1}. #{slot[:name]} ✅\n"
          end
        else
          message += "#{idx + 1}. _Свободно_ ⚪\n"
        end
      end

      message += "\n"

      # Добавляем информацию о слотах без тренера
      message += "👥 *Без тренера*:\n"
      slots_without_trainer.each_with_index do |slot, idx|
        if slot[:name]
          if CANCELLED_SLOT_NAMES.include?(slot[:name].downcase)
            message += "#{idx + 1}. 🚫 _Отменен_ ❌\n"
          else
            message += "#{idx + 1}. #{slot[:name]} ✅\n"
          end
        else
          message += "#{idx + 1}. _Свободно_ ⚪\n"
        end
      end

      # Проверяем дополнительные слоты
      additional_slots = []
      if next_date_row.length > 15
        for i in 15..(next_date_row.length - 1)
          slot_name = next_date_row[i]
          clean_name = slot_name.nil? ? nil : slot_name.strip.downcase

          if slot_name && !slot_name.strip.empty? && !IGNORED_SLOT_NAMES.include?(clean_name)
            additional_slots << {
              index: i,
              name: slot_name.strip
            }
          else
            additional_slots << {
              index: i,
              name: nil
            }
          end
        end
      end

      # Если первые 4 слота без тренера отменены — все дополнительные тоже считаем отменёнными
      if slots_without_trainer.first(4).all? { |s| s[:name] == "Отменен" }
        additional_slots.each { |slot| slot[:name] = "Отменен" }
      end

      # Добавляем дополнительные слоты если есть
      if additional_slots.any?
        message += "\n👥 *Дополнительные слоты*:\n"
        additional_slots.each_with_index do |slot, idx|
          if slot[:name]
            if slot[:name] == "Отменен"
              message += "#{idx + 1}. 🚫 _Отменен_ ❌\n"
            else
              message += "#{idx + 1}. #{slot[:name]} ✅\n"
            end
          else
            message += "#{idx + 1}. _Свободно_ ⚪\n"
          end
        end
      end

      # Собираем все свободные слоты для клавиатуры
      all_slots = slots_with_trainer + slots_without_trainer + additional_slots
      empty_slots = all_slots.select { |s| s[:name].nil? }

      # Формируем клавиатуру
      keyboard_buttons = []

      if empty_slots.any?
        keyboard_buttons = empty_slots.map do |slot|
          # Определяем тип слота для отображения
          slot_type = if slot[:index] >= 15
                        "Доп. слот #{slot[:index] - 14}"
                      elsif slot[:index] >= 7
                        "Без тренера #{slot[:index] - 6}"
                      else
                        "С тренером #{slot[:index] - 2}"
                      end

          Telegram::Bot::Types::InlineKeyboardButton.new(
            text: slot_type,
            callback_data: "book:#{next_date_str}:#{slot[:index]}"
          )
        end

        message += "\n💡 Выберите свободный слот для записи:"
      else
        message += "\n❌ К сожалению, все слоты заняты или отменены."
      end

      # Добавляем кнопку "Назад"
      keyboard_buttons_with_back = keyboard_buttons.each_slice(2).to_a
      keyboard_buttons_with_back << [
        Telegram::Bot::Types::InlineKeyboardButton.new(
          text: "« Назад к меню",
          callback_data: "menu:back"
        )
      ]

      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: keyboard_buttons_with_back
      )

      {
        text: message,
        keyboard: keyboard
      }
    end

    def show_available_slots(chat_id)
      slots_content = get_available_slots_content()

      if slots_content
        send_message(chat_id, slots_content[:text], reply_markup: slots_content[:keyboard])
      else
        send_message(chat_id, "К сожалению, не удалось найти предстоящие игры в таблице.")
      end
    end

    def show_slot_options(chat_id, date_str, slots, header)
      # Формируем описание доступных слотов
      message = "👥 *#{header}*:\n"

      slots.each_with_index do |slot, idx|
        if slot[:name]
          # Проверяем, является ли слот отмененным
        if CANCELLED_SLOT_NAMES.include?(slot[:name].downcase)
            message += "#{idx + 1}. 🚫 _Отменен_ ❌\n"
          else
            message += "#{idx + 1}. #{slot[:name]} ✅\n"
          end
        else
          message += "#{idx + 1}. _Свободно_ ⚪\n"
        end
      end

      send_message(chat_id, message)

      # Создаем клавиатуру с кнопками только для свободных слотов (не отмененных)
      empty_slots = slots.select { |s| s[:name].nil? }
      # Если нет свободных слотов — не показываем клавиатуру
      return if empty_slots.empty?

      if empty_slots.any?
        keyboard_buttons = empty_slots.map do |slot|
          Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "Слот #{slots.index { |s| s[:index] == slot[:index] } + 1}",
            callback_data: "book:#{date_str}:#{slot[:index]}"
          )
        end

        if keyboard_buttons.any?
          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [keyboard_buttons]
          )

          send_message(
            chat_id,
            "Выберите свободный слот для записи:",
            reply_markup: keyboard
          )
        end
      else
        send_message(chat_id, "К сожалению, все слоты заняты или отменены.")
      end
    end

    def handle_booking_callback(callback_query)
      data = callback_query.data
      _, date_str, slot_index = data.split(":")
      slot_index = slot_index.to_i

      user_id = callback_query.from.id
      user = @user_registry.find_by_telegram_id(user_id)

      unless user && user.sheet_name
        @bot_instance.api.answer_callback_query(
          callback_query_id: callback_query.id,
          text: "Сначала укажите ваше имя с помощью команды /myname"
        )
        return
      end

      # Записываем пользователя в выбранный слот
      begin
        # Получаем данные из таблицы
        spreadsheet_data = @sheets_formatter.get_spreadsheet_data

        # Находим нужную строку по дате
        row_index = nil
        row = nil
        spreadsheet_data.each_with_index do |r, idx|
          next unless r[0] == date_str

          row_index = idx
          row = r
          break
        end

        unless row_index
          @bot_instance.api.answer_callback_query(
            callback_query_id: callback_query.id,
            text: "Ошибка: дата не найдена в таблице"
          )
          return
        end

        # Проверяем, не записан ли пользователь уже на эту дату
        user_already_in_slots = false

        # Объявляем переменные здесь, за пределами цикла
        existing_col_letter = nil
        existing_slot_type = nil
        existing_slot_num = nil

        # Проверяем все возможные колонки, в которых могут быть слоты игроков
        max_col_index = [row.length - 1, 30].min # Ограничиваем максимальную колонку для проверки

        (3..max_col_index).each do |col_idx|
          next if col_idx == slot_index # Пропускаем текущий выбранный слот
          next if row[col_idx].nil? || row[col_idx].strip.empty? # Пропускаем пустые ячейки

          # Проверяем, есть ли имя пользователя в слоте
          next unless row[col_idx].strip == user.sheet_name

          user_already_in_slots = true

          # Находим номер колонки, где уже записан пользователь
          existing_col_letter = (col_idx + "A".ord).chr

          # Определяем тип слота и его номер в зависимости от колонки
          if col_idx >= 15
            existing_slot_type = "доп. слот"
            existing_slot_num = col_idx - 14
          elsif col_idx >= 7
            existing_slot_type = "без тренера"
            existing_slot_num = col_idx - 6
          else
            existing_slot_type = "с тренером"
            existing_slot_num = col_idx - 2
          end

          break
        end

        # Если пользователь уже записан на эту дату, отклоняем запись
        if user_already_in_slots
          @bot_instance.api.answer_callback_query(
            callback_query_id: callback_query.id,
            text: "Вы уже записаны на #{date_str} (слот #{existing_slot_num} #{existing_slot_type})!",
            show_alert: true
          )
          return
        end

        # Устанавливаем имя пользователя в выбранный слот
        col_letter = (slot_index + "A".ord).chr
        cell_a1 = "#{col_letter}#{row_index + 1}"

        # Определяем тип слота и его номер в зависимости от колонки
        if slot_index >= 15
          slot_type = "доп. слот"
          slot_num = slot_index - 14
        elsif slot_index >= 7
          slot_type = "без тренера"
          slot_num = slot_index - 6
        else
          slot_type = "с тренером"
          slot_num = slot_index - 2
        end

        if update_cell_value(Config.default_sheet_name, cell_a1, user.sheet_name)
          @bot_instance.api.answer_callback_query(
            callback_query_id: callback_query.id,
            text: "Вы успешно записаны на #{date_str}!"
          )

          # Успешное сообщение с возвращением к главному меню
          success_message = "✅ Вы успешно записались на #{date_str} в слот #{slot_num} #{slot_type}!\n\n"
          menu_text, keyboard = get_main_menu_content(user)

          edit_or_send_menu(
            callback_query.message.chat.id,
            success_message + menu_text.split("\n")[2..-1].join("\n"), # Убираем "Главное меню:" из начала
            keyboard,
            callback_query.message.message_id
          )

          @sheets_formatter.apply_format(Config.default_sheet_name, cell_a1, :text_color, "green")
        else
          @bot_instance.api.answer_callback_query(
            callback_query_id: callback_query.id,
            text: "Произошла ошибка при записи"
          )
        end
      rescue StandardError => e
        log(:error, "Ошибка при бронировании слота: #{e.message}\n#{e.backtrace.join("\n")}")
        @bot_instance.api.answer_callback_query(
          callback_query_id: callback_query.id,
          text: "Произошла ошибка при записи. Попробуйте позже."
        )
      end
    end

    def update_cell_value(sheet_name, cell_a1, value)
      # Создаем объект ValueRange с новым значением
      value_range = Google::Apis::SheetsV4::ValueRange.new(
        range: "#{sheet_name}!#{cell_a1}",
        values: [[value]]
      )

      # Отправляем запрос на обновление
      @sheets_formatter.authenticated_service.update_spreadsheet_value(
        @sheets_formatter.spreadsheet_id,
        "#{sheet_name}!#{cell_a1}",
        value_range,
        value_input_option: "USER_ENTERED"
      )

      # Сбрасываем кэш данных таблицы
      @sheets_formatter.clear_cache

      true
    rescue StandardError => e
      log(:error, "Ошибка при обновлении ячейки #{cell_a1}: #{e.message}")
      false
    end

    def ensure_pinned_menu(chat_id, user)
    # Проверяем не чаще раза в 100 минут для каждого чата
    last_check = @pinned_menu_cache[chat_id]
    return false if last_check && Time.now - last_check < 600 # 10 минут

    @pinned_menu_cache[chat_id] = Time.now

      begin
        # Получаем информацию о закрепленном сообщении
        chat = @bot_instance.api.get_chat(chat_id: chat_id)

        # Если нет закрепленного сообщения
        if chat["result"]["pinned_message"].nil?
          log(:info, "Закрепленное сообщение отсутствует в чате #{chat_id}, создаю новое")
          send_and_pin_menu(chat_id, user)
          return true
        end

        # Проверяем, является ли закрепленное сообщение нашим меню
        pinned_message = chat["result"]["pinned_message"]
        pinned_text = pinned_message["text"]

        # Если закрепленное сообщение не содержит текст меню бота
        if pinned_text.nil? || !pinned_text.include?("ЗАКРЕПЛЕННОЕ МЕНЮ") || !pinned_text.include?("Главное меню:")
          log(:info, "Закрепленное сообщение в чате #{chat_id} не является меню бота, обновляю")
          update_pinned_menu(chat_id, user)
          return true
        end

        log(:debug, "Закрепленное меню актуально в чате #{chat_id}")
        return false

      rescue Telegram::Bot::Exceptions::ResponseError => e
        log(:warn, "Не удалось проверить закрепленное сообщение в чате #{chat_id}: #{e.message}")
        # В случае ошибки, попробуем закрепить меню
        send_and_pin_menu(chat_id, user)
        return true
      end
    end

    def handle_show_slots(message, _captures)
      user_id = message.from.id
      user = @user_registry.find_by_telegram_id(user_id)

      unless user
        # Автоматически регистрируем пользователя, если он еще не зарегистрирован
        user = User.from_telegram_user(message.from)
        @user_registry.register_user(user)
      end

      # Если у пользователя не указано имя в таблице, предлагаем указать
      unless user.sheet_name
        send_message(
          message.chat.id,
          "⚠️ Сначала укажите своё имя в таблице с помощью команды `/myname <Имя_в_таблице>`"
        )
        return
      end

      # Показываем доступные слоты
      show_available_slots(message.chat.id)
    end

    def handle_unknown_command(message)
      show_main_menu(message.chat.id, "Неизвестная команда или неверный формат. Выберите действие из меню:")
    end

    def send_message(chat_id, text, parse_mode: "Markdown", **options)
      return unless @bot_instance

      sleep(rand(0.3..1.5))

      log(:debug, "-> Отправка в #{chat_id}: #{text.gsub("\n", " ")}")
      @bot_instance.api.send_message(chat_id: chat_id, text: text, parse_mode: parse_mode, **options)
    rescue Telegram::Bot::Exceptions::ResponseError => e
      log_telegram_api_error(e, chat_id)

      if e.error_code == 429
        retry_after = e.response && e.response.respond_to?(:parameters) ? e.response.parameters["retry_after"] : 5
        retry_after = [retry_after.to_i, 3].max

        log(:warn, "Получена ошибка превышения лимитов Telegram API. Ожидание #{retry_after} секунд...")
        sleep(retry_after)

        begin
          @bot_instance.api.send_message(chat_id: chat_id, text: text, parse_mode: parse_mode, **options)
          log(:info, "Повторная отправка успешна после ожидания")
        rescue Telegram::Bot::Exceptions::ResponseError => retry_error
          log(:error, "Не удалось отправить сообщение даже после ожидания: #{retry_error.message}")
        end
      end
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

    def log_telegram_api_error(error, chat_id = "N/A")
      log(:error, "Ошибка Telegram API при отправке в чат #{chat_id}: #{error.message} (Код: #{error.error_code})")
      case error.error_code
      when 400 # Bad Request
        log(:warn, "   -> Возможно, неверный chat_id или ошибка разметки Markdown?")
      when 403 # Forbidden
        log(:warn, "   -> Бот заблокирован пользователем или удален из чата #{chat_id}.")
      when 429 # Too Many Requests
        log(:warn, "   -> Превышены лимиты Telegram API. Нужно замедлиться.")
        sleep(1)
      end
    end

    def log(level, message)
      puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] [#{level.upcase}] [TelegramBot] #{message}"
    end
  end
end
