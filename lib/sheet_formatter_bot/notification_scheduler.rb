require "date"
require "time"
require "tzinfo"

module SheetFormatterBot
  class NotificationScheduler
    attr_reader :bot, :sheets_formatter

    def initialize(bot:, sheets_formatter:)
      @bot = bot
      @sheets_formatter = sheets_formatter
      @user_registry = bot.user_registry
      @running = false
      @thread = nil
      @sent_notifications = {} # Хеш для отслеживания отправленных уведомлений

      # Загружаем конфигурацию из Config
      @hours_before = Config.notification_hours_before
      @tennis_time = Config.tennis_default_time
      @check_interval = Config.notification_check_interval
      @timezone = TZInfo::Timezone.get(Config.timezone || "Asia/Yekaterinburg")
    end

    def start
      return if @running

      @running = true
      @thread = Thread.new do
        log(:info, "Запуск планировщика уведомлений")
        begin
          scheduler_loop
        rescue StandardError => e
          log(:error, "Ошибка в потоке планировщика: #{e.message}\n#{e.backtrace.join("\n")}")
          stop
        end
      end
    end

    def stop
      return unless @running

      @running = false
      @thread&.join(5) # Даем 5 секунд на завершение
      @thread&.kill if @thread&.alive?
      @thread = nil
      log(:info, "Планировщик уведомлений остановлен")
    end

    def get_user_current_attendance_status(sheet_name, date_str)
      # Получаем данные таблицы
      spreadsheet_data = @sheets_formatter.get_spreadsheet_data

      # Очищаем имя от лишних пробелов
      clean_player_name = sheet_name.strip

      # Проходим по данным и ищем ячейку с именем игрока
      spreadsheet_data.each_with_index do |row, row_idx|
        next unless row[0] == date_str # Ищем только в строке с нужной датой

        # Проверяем ячейки в диапазоне, где могут быть имена игроков (колонки 3-10)
        (3..10).each do |col_idx|
          cell = row[col_idx].to_s

          # Сравниваем с учетом возможных пробелов в конце
          next unless cell.strip == clean_player_name

          # Проверяем цвет текста в этой ячейке
          col_letter = (col_idx + "A".ord).chr
          cell_a1 = "#{col_letter}#{row_idx + 1}"

          formats = @sheets_formatter.get_cell_formats(Config.default_sheet_name, cell_a1)
          if formats && formats[:text_color]
            case formats[:text_color]
            when "green"
              return "yes"
            when "red"
              return "no"
            when "yellow"
              return "maybe"
            end
          end

          # Если формат не установлен, считаем что статус не определен
          return nil
        end
      end

      # Не нашли имя игрока на указанную дату
      nil
    rescue StandardError => e
      log(:error, "Ошибка при получении статуса посещения: #{e.message}")
      nil
    end

    def handle_attendance_callback(callback_query)
      data = callback_query.data
      action, *params = data.split(":")

      case action
      when "attendance"
        response = params[0]
        date_str = params[1]

        is_explicit_confirmation = response.start_with?("confirm_")

        if is_explicit_confirmation
          orig_response = response
          response = response.sub("confirm_", "")
          log(:info, "Получено подтверждение статуса: #{orig_response} -> #{response}")
        end

        if response == "no_reask"
          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "✅ Да",
                  callback_data: "attendance:yes:#{date_str}"
                ),
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "❌ Нет",
                  callback_data: "attendance:no:#{date_str}"
                ),
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "🤔 Не уверен",
                  callback_data: "attendance:maybe:#{date_str}"
                )
              ]
            ]
          )

          message = <<~MESSAGE
            🎾 *ИЗМЕНЕНИЕ СТАТУСА УЧАСТИЯ*

            📅 Дата: *#{date_str}*

            Пожалуйста, выберите новый статус участия:
          MESSAGE

          begin
            @bot.bot_instance.api.edit_message_reply_markup(
              chat_id: callback_query.message.chat.id,
              message_id: callback_query.message.message_id
            )

            @bot.bot_instance.api.send_message(
              chat_id: callback_query.message.chat.id,
              text: message,
              parse_mode: "Markdown",
              reply_markup: keyboard
            )

            @bot.bot_instance.api.answer_callback_query(
              callback_query_id: callback_query.id,
              text: "Выберите свой статус участия"
            )
          rescue StandardError => e
            log(:error, "Ошибка при обработке ответа 'no_reask': #{e.message}")
          end

          return
        end

        return unless %w[yes no maybe].include?(response)

        telegram_id = callback_query.from.id
        user = @user_registry.find_by_telegram_id(telegram_id)

        unless user
          log(:warn, "Пользователь не найден для ID: #{telegram_id}")
          return
        end

        sheet_name = user.sheet_name

        unless sheet_name && !sheet_name.empty?
          log(:warn, "У пользователя #{user.display_name} не указано имя в таблице")
          @bot.bot_instance.api.answer_callback_query(
            callback_query_id: callback_query.id,
            text: "Ошибка: ваше имя не найдено в таблице. Укажите его через команду /myname или главное меню.",
            show_alert: true
          )
          return
        end

        previous_status = get_user_current_attendance_status(sheet_name, date_str)

        is_confirmation = is_explicit_confirmation || (previous_status == response)
        is_changing = !is_confirmation && !previous_status.nil?

        log(:info,
            "Обработка ответа от #{user.display_name}: response=#{response}, previous=#{previous_status}, is_explicit_confirmation=#{is_explicit_confirmation}, is_confirmation=#{is_confirmation}")

        should_update_sheet = !is_confirmation

        if should_update_sheet
          color = case response
                  when "yes" then "green"
                  when "no" then "red"
                  when "maybe" then "yellow"
                  end

          log(:info, "Имя в таблице: '#{sheet_name}', поиск ячейки для обновления статуса на #{color}...")
          update_successful = update_attendance_in_sheet(date_str, sheet_name, color)
        else
          log(:info, "Пользователь #{user.display_name} подтвердил текущий статус '#{response}' - таблица не обновляется")
          update_successful = true
        end

        if update_successful || is_confirmation
          message = if is_confirmation
                      case response
                      when "yes"
                        "✅ Спасибо за подтверждение! Ждём вас на игре."
                      when "no"
                        "❌ Вы подтвердили свой отказ от участия."
                      when "maybe"
                        "🤔 Вы подтвердили свой статус 'Не уверен'."
                      end
                    else
                      case response
                      when "yes"
                        if is_changing && previous_status
                          "✅ Вы изменили свой ответ на 'Да'. Будем ждать вас на игре!"
                        else
                          "✅ Отлично! Ваш ответ 'Да' зарегистрирован."
                        end
                      when "no"
                        if is_changing && previous_status
                          "❌ Вы изменили свой ответ на 'Нет'. Жаль, что не сможете прийти."
                        else
                          "❌ Жаль! Ваш ответ 'Нет' зарегистрирован."
                        end
                      when "maybe"
                        if is_changing && previous_status
                          "🤔 Вы изменили свой ответ на 'Не уверен'. Надеемся на положительное решение!"
                        else
                          "🤔 Понятно. Ваш ответ 'Не уверен' зарегистрирован."
                        end
                      end
                    end

          @bot.bot_instance.api.answer_callback_query(
            callback_query_id: callback_query.id,
            text: "Ваш ответ принят!"
          )

          @bot.bot_instance.api.edit_message_text(
            chat_id: callback_query.message.chat.id,
            message_id: callback_query.message.message_id,
            text: "#{callback_query.message.text}\n\n#{message}",
            reply_markup: nil
          )
        else
          @bot.bot_instance.api.answer_callback_query(
            callback_query_id: callback_query.id,
            text: "Произошла ошибка при обновлении данных. Убедитесь, что ваше имя правильно указано в таблице.",
            show_alert: true
          )
        end

      when "register"
        date_str = params[0]
        cell_a1 = params[1]

        telegram_id = callback_query.from.id
        user = @user_registry.find_by_telegram_id(telegram_id)

        unless user
          log(:warn, "Пользователь не найден для ID: #{telegram_id}")
          @bot.bot_instance.api.answer_callback_query(
            callback_query_id: callback_query.id,
            text: "Не найден зарегистрированный пользователь с вашим ID",
            show_alert: true
          )
          return
        end

        sheet_name = user.sheet_name

        unless sheet_name && !sheet_name.empty?
          log(:warn, "У пользователя #{user.display_name} не указано имя в таблице")
          @bot.bot_instance.api.answer_callback_query(
            callback_query_id: callback_query.id,
            text: "Ошибка: ваше имя не найдено в таблице. Укажите его через команду /myname или главное меню.",
            show_alert: true
          )
          return
        end

        log(:info, "Запись игрока #{sheet_name} на игру #{date_str} в ячейку #{cell_a1}")

        begin
          @sheets_formatter.update_cell_value(Config.default_sheet_name, cell_a1, sheet_name)

          @bot.bot_instance.api.answer_callback_query(
            callback_query_id: callback_query.id,
            text: "Вы успешно записаны на игру!"
          )

          message = <<~MESSAGE
            🎾 *ЗАПИСЬ НА ИГРУ*

            ✅ Вы успешно записаны на игру #{date_str}!

            Теперь вы можете изменить свой статус участия:
          MESSAGE

          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "✅ Да",
                  callback_data: "attendance:yes:#{date_str}"
                ),
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "❌ Нет",
                  callback_data: "attendance:no:#{date_str}"
                ),
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "🤔 Не уверен",
                  callback_data: "attendance:maybe:#{date_str}"
                )
              ]
            ]
          )

          @bot.bot_instance.api.edit_message_text(
            chat_id: callback_query.message.chat.id,
            message_id: callback_query.message.message_id,
            text: message,
            parse_mode: "Markdown",
            reply_markup: keyboard
          )

          log(:info, "Игрок #{sheet_name} успешно записан на игру #{date_str}")
        rescue StandardError => e
          log(:error, "Ошибка при записи игрока #{sheet_name} на игру: #{e.message}")
          @bot.bot_instance.api.answer_callback_query(
            callback_query_id: callback_query.id,
            text: "Произошла ошибка при записи на игру. Пожалуйста, попробуйте позже.",
            show_alert: true
          )
        end
      end
    end

    def send_test_notification(user, date_str = nil)
      log(:info, "Отправка запроса на изменение статуса для #{user.display_name}")

      unless date_str
        today = @timezone.now.to_date
        tomorrow = today.next_day

        spreadsheet_data = @sheets_formatter.get_spreadsheet_data

        today_games = find_games_for_date(spreadsheet_data, today.strftime("%d.%m.%Y"))
        tomorrow_games = find_games_for_date(spreadsheet_data, tomorrow.strftime("%d.%m.%Y"))

        if today_games.any?
          nearest_game = today_games.first
          date_str = nearest_game[:date]
          time_description = "сегодня"
          game_time = nearest_game[:time]
          game_place = nearest_game[:place]
        elsif tomorrow_games.any?
          nearest_game = tomorrow_games.first
          date_str = nearest_game[:date]
          time_description = "завтра"
          game_time = nearest_game[:time]
          game_place = nearest_game[:place]
        else
          begin
            @bot.bot_instance.api.send_message(
              chat_id: user.telegram_id,
              text: "🎾 В ближайшие два дня игр не запланировано. Проверьте расписание позже."
            )
            log(:info, "Отправлено сообщение об отсутствии ближайших игр для #{user.display_name}")
            return true
          rescue Telegram::Bot::Exceptions::ResponseError => e
            log(:error, "Ошибка при отправке сообщения для #{user.display_name}: #{e.message}")
            return false
          end
        end
      else
        spreadsheet_data = @sheets_formatter.get_spreadsheet_data
        games = find_games_for_date(spreadsheet_data, date_str)

        log(:info, "Поиск игр на дату #{date_str}, найдено: #{games.count}")
        log(:debug, "Содержимое первых строк таблицы: #{spreadsheet_data.first(3).inspect}")

        if games.any?
          nearest_game = games.first
          today = @timezone.now.to_date
          game_date = Date.strptime(date_str, "%d.%m.%Y")

          if game_date == today
            time_description = "сегодня"
          elsif game_date == today.next_day
            time_description = "завтра"
          else
            time_description = date_str
          end

          game_time = nearest_game[:time]
          game_place = nearest_game[:place]
        else
          begin
            @bot.bot_instance.api.send_message(
              chat_id: user.telegram_id,
              text: "🎾 На дату #{date_str} игр не запланировано."
            )
            log(:info, "Отправлено сообщение об отсутствии игр на #{date_str} для #{user.display_name}")
            return true
          rescue Telegram::Bot::Exceptions::ResponseError => e
            log(:error, "Ошибка при отправке сообщения для #{user.display_name}: #{e.message}")
            return false
          end
        end
      end

      full_row_data = nil
      row_idx = nil
      spreadsheet_data = @sheets_formatter.get_spreadsheet_data

      spreadsheet_data.each_with_index do |row, idx|
        if row[0] == date_str
          full_row_data = row
          row_idx = idx + 1
          break
        end
      end

      is_registered = false
      available_slots = []

      if full_row_data
        clean_player_name = user.sheet_name.strip

        (3..10).each do |col_idx|
          cell_value = full_row_data[col_idx].to_s.strip

          if cell_value.empty? || cell_value.downcase == "отмена"
            col_letter = (col_idx + "A".ord).chr
            available_slots << "#{col_letter}#{row_idx}"
          elsif cell_value == clean_player_name
            is_registered = true
            break
          end
        end
      end

      current_status = get_user_current_attendance_status(user.sheet_name, date_str)
      status_text = case current_status
                  when "yes"
                    "✅ Да (вы подтвердили участие)"
                  when "no"
                    "❌ Нет (вы отказались)"
                  when "maybe"
                    "🤔 Не уверен"
                  else
                    "⚪ Не указан"
                  end

      if is_registered
        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "✅ Да",
                callback_data: "attendance:yes:#{date_str}"
              ),
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "❌ Нет",
                callback_data: "attendance:no:#{date_str}"
              ),
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "🤔 Не уверен",
                callback_data: "attendance:maybe:#{date_str}"
              )
            ]
          ]
        )
      else
        if available_slots.any?
          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "📝 Записаться на игру",
                  callback_data: "register:#{date_str}:#{available_slots.first}"
                )
              ]
            ]
          )
        else
          keyboard = nil
        end
      end

      if is_registered
        message = <<~MESSAGE
          🎾 *ИЗМЕНЕНИЕ СТАТУСА УЧАСТИЯ*

          📅 Дата: *#{date_str}* (#{time_description})
          🕒 Время: *#{game_time}*
          📍 Место: *#{game_place}*

          #{current_status ? "Ваш текущий статус: #{status_text}" : ""}

          Выберите свой статус участия:
        MESSAGE
      else
        if available_slots.any?
          message = <<~MESSAGE
            🎾 *ЗАПИСЬ НА ИГРУ*

            📅 Дата: *#{date_str}* (#{time_description})
            🕒 Время: *#{game_time}*
            📍 Место: *#{game_place}*

            Вы не записаны на эту игру.
            Доступно свободных мест: #{available_slots.size}
          MESSAGE
        else
          message = <<~MESSAGE
            🎾 *ИНФОРМАЦИЯ ОБ ИГРЕ*

            📅 Дата: *#{date_str}* (#{time_description})
            🕒 Время: *#{game_time}*
            📍 Место: *#{game_place}*

            Вы не записаны на эту игру.
            К сожалению, все места уже заняты.
          MESSAGE
        end
      end

      begin
        @bot.bot_instance.api.send_message(
          chat_id: user.telegram_id,
          text: message,
          parse_mode: "Markdown",
          reply_markup: keyboard
        )
        log(:info, "Запрос на изменение статуса успешно отправлен для #{user.display_name} на дату #{date_str}")
        true
      rescue Telegram::Bot::Exceptions::ResponseError => e
        log(:error, "Ошибка при отправке запроса для #{user.display_name}: #{e.message}")
        false
      end
    end

    private

    def scheduler_loop
      while @running
        check_and_send_notifications

        sleep(@check_interval)
      end
    end

    def check_and_send_notifications
      cleanup_sent_notifications

      now = @timezone.now
      today = now.to_date
      tomorrow = today.next_day

      log(:debug, "Проверка уведомлений на #{today}")

      spreadsheet_data = @sheets_formatter.get_spreadsheet_data

      current_hour = now.hour

      afternoon_hour = Config.morning_notification_hour
      evening_hour = Config.evening_notification_hour

      today_games = find_games_for_date(spreadsheet_data, today.strftime("%d.%m.%Y"))

      tomorrow_games = find_games_for_date(spreadsheet_data, tomorrow.strftime("%d.%m.%Y"))

      if current_hour == afternoon_hour
        if today_games.any?
          log(:info, "Отправляем дневное напоминание об играх сегодня (всего: #{today_games.count})")
          today_games.each do |game|
            send_notifications_for_game(game, "сегодня", "дневное")
          end
        end

        if tomorrow_games.any?
          log(:info, "Отправляем дневное напоминание об играх завтра (всего: #{tomorrow_games.count})")
          tomorrow_games.each do |game|
            send_notifications_for_game(game, "завтра", "дневное")
          end
        end

        if today_games.any?
          log(:info, "Отправляем уведомление в общий чат о сегодняшних играх")
          today_games.each do |game|
            send_general_chat_notification(game, "сегодня")
          end
        end
      end

      if current_hour == evening_hour
        if today_games.any?
          log(:info, "Отправляем вечернее напоминание об играх сегодня (всего: #{today_games.count})")
          today_games.each do |game|
            send_notifications_for_game(game, "сегодня", "вечернее")
          end
        end

        if tomorrow_games.any?
          log(:info, "Отправляем вечернее напоминание об играх завтра (всего: #{tomorrow_games.count})")
          tomorrow_games.each do |game|
            send_notifications_for_game(game, "завтра", "вечернее")
          end
        end

        if tomorrow_games.any?
          log(:info, "Отправляем уведомление в общий чат о завтрашних играх")
          tomorrow_games.each do |game|
            send_general_chat_notification(game, "завтра")
          end
        end
      end

      if Config.final_reminder_notification && today_games.any?
        today_games.each do |game|
          game_hour, game_min = game[:time].split(":").map(&:to_i)

          hours_before = game_hour - current_hour
          if hours_before == 2 && now.min < 5
            log(:info, "Отправляем напоминание за два часа до игры в #{game[:time]}")
            send_notifications_for_game(game, "сегодня", "скорое")
          end
        end
      end
    rescue StandardError => e
      log(:error, "Ошибка при проверке уведомлений: #{e.message}\n#{e.backtrace.join("\n")}")
    end

    def find_games_for_date(spreadsheet_data, date_str)
      games = []

      log(:debug, "Ищем игры на дату: #{date_str}, формат поиска: #{date_str.gsub('.', '-')}")

      spreadsheet_data.each_with_index do |row, idx|
        next if row[0].nil? || row[0].empty?

        row_date = row[0].strip
        log(:debug, "Проверяем строку #{idx}: дата='#{row_date}'")

        if row_date == date_str ||
           row_date == date_str.gsub('.', '/') ||
           row_date == date_str.gsub('.', '-')

          time = row[1] || @tennis_time
          place = row[2] || "обычное место"

          players = row[3..10].compact.reject(&:empty?)

          games << {
            date: date_str,
            time: time,
            place: place,
            players: players
          }

          log(:info, "Найдена игра на дату #{date_str} в строке #{idx}: время=#{time}, место=#{place}, игроков=#{players.size}")
        end
      end

      games
    end

    def send_notifications_for_game(game, time_description, notification_type)
      log(:info, "Отправляем #{notification_type} уведомление о игре #{time_description} в #{game[:time]}")

      # Уникальный ключ для этой рассылки
      today = @timezone.now.to_date.strftime("%Y-%m-%d")
      notification_key = "#{today}:#{game[:date]}:#{notification_type}"

      # Если на сегодня такие уведомления уже отправлялись, пропускаем
      if @sent_notifications[notification_key]
        log(:info, "Уведомления #{notification_type} для игры #{game[:date]} уже были отправлены сегодня")
        return
      end

      players_notified = 0

      # Отправляем уведомления только реальным игрокам (не "отмена")
      game[:players].each do |player_name|
        next if player_name.strip.downcase == "отмена"

        user = @user_registry.find_by_name(player_name)
        if user
          send_game_notification_to_user(user, game, time_description, notification_type)
          players_notified += 1
        else
          log(:warn, "Telegram-пользователь для игрока не найден: #{player_name}")
        end
      end

      # Отмечаем, что уведомления отправлены (только если были отправлены хотя бы 1)
      @sent_notifications[notification_key] = Time.now if players_notified > 0
    end

    def send_general_chat_notification(game, time_description)
      general_chat_id = Config.general_chat_id
      return unless general_chat_id # Если ID общего чата не указан, ничего не делаем

      # Создаем уникальный ключ для отслеживания отправленных уведомлений в общий чат
      today = @timezone.now.to_date.strftime("%Y-%m-%d")
      notification_key = "general_chat:#{today}:#{game[:date]}:#{time_description}"

      # Проверяем, было ли уже отправлено это уведомление сегодня
      if @sent_notifications[notification_key]
        log(:info, "Уведомление в общий чат о игре #{game[:date]} (#{time_description}) уже было отправлено сегодня")
        return
      end

      # Получаем полную строку данных из таблицы
      full_row_data = nil
      row_idx = nil
      spreadsheet_data = @sheets_formatter.get_spreadsheet_data

      spreadsheet_data.each_with_index do |row, idx|
        next unless row[0] == game[:date]

        full_row_data = row
        row_idx = idx + 1 # +1 потому что индексация в A1 нотации начинается с 1
        break
      end

      return unless full_row_data

      log(:info, "Найдена строка для даты #{game[:date]}, индекс строки: #{row_idx}")

      # Формируем сообщение
      slots_with_trainer = []
      slots_without_trainer = []

      # Анализируем слоты с тренером (колонки 3-6)
      process_slots(full_row_data, 3..6, slots_with_trainer, row_idx)

      # Анализируем слоты без тренера (колонки 7-10)
      process_slots(full_row_data, 7..10, slots_without_trainer, row_idx)

      # Проверяем, есть ли доступные слоты (не отмененные и не занятые)
      slots_with_trainer_available = slots_with_trainer.any? { |s| s == "Свободно" }
      slots_without_trainer_available = slots_without_trainer.any? { |s| s == "Свободно" }

      # Формируем текст для слотов, всегда показывая детальную информацию
      slots_with_trainer_text = format_slots_text(slots_with_trainer)
      slots_without_trainer_text = format_slots_text(slots_without_trainer)

      # Если все слоты отменены в обоих секциях, можно пропустить уведомление
      if slots_with_trainer.all? { |s| s == "Отменен" } && slots_without_trainer.all? { |s| s == "Отменен" }
        log(:info, "Все слоты отменены на #{game[:date]} - уведомление не отправляется")
        return
      end

      # Определяем, все ли места заняты
      all_slots_busy = !slots_with_trainer_available && !slots_without_trainer_available &&
                       !slots_with_trainer.all? { |s| s == "Отменен" } &&
                       !slots_without_trainer.all? { |s| s == "Отменен" }

      safe_username = escape_markdown(Config.telegram_bot_username)

      # Формируем сообщение
      message = <<~MESSAGE
        📅 #{time_description.capitalize} игра в теннис:
        🕒 Время: *#{game[:time]}*
        📍 Место: *#{game[:place]}*

        👥 *С тренером*:
        #{slots_with_trainer_text}

        👥 *Без тренера*:
        #{slots_without_trainer_text}

        #{all_slots_busy ? "Если вы хотите отменить свою запись или изменить статус участия,\nвоспользуйтесь ботом: @#{safe_username}" : "Записаться на игру можно через бота: @#{safe_username}"}
      MESSAGE

      log(:info, "Подготовлено сообщение для общего чата")

      # Отправляем сообщение в общий чат
      begin
        @bot.bot_instance.api.send_message(
          chat_id: general_chat_id,
          text: message,
          parse_mode: "Markdown"
        )

        # Запоминаем, что уведомление отправлено
        @sent_notifications[notification_key] = Time.now

        log(:info, "Уведомление успешно отправлено в общий чат")
      rescue Telegram::Bot::Exceptions::ResponseError => e
        log(:error, "Ошибка при отправке уведомления в общий чат: #{e.message}")
      end
    end

    def escape_markdown(text)
      return "" if text.nil?

      # Экранируем символы Markdown: * _ [ ] ( ) ~ ` > # + - = | { } . !
      text.to_s.gsub(/([_*\[\]()~`>#+\-=|{}.!])/, '\\\\\\1')
    end

    # Вспомогательный метод для обработки слотов
    def process_slots(row_data, range, slots_array, row_idx)
      range.each do |i|
        slot_name = row_data[i]

        if slot_name.nil? || slot_name.strip.empty?
          slots_array << "Свободно"
          next
        end

        if slot_name.strip.downcase == "отмена"
          slots_array << "Отменен"
          next
        end

        # Получаем формат ячейки для определения статуса
        col_letter = (i + "A".ord).chr
        cell_a1 = "#{col_letter}#{row_idx}"
        formats = @sheets_formatter.get_cell_formats(Config.default_sheet_name, cell_a1)

        log(:debug, "Ячейка #{cell_a1}, имя: '#{slot_name}', форматы: #{formats.inspect}")

        # Определяем статус по цвету текста из полученных форматов
        status_emoji = "⚪" # По умолчанию - нет статуса

        if formats && formats[:text_color]
          case formats[:text_color]
          when "green"
            status_emoji = "✅" # подтвердил участие
          when "red"
            status_emoji = "❌" # отказался
          when "yellow"
            status_emoji = "🤔" # не уверен
          end
          log(:debug, "Статус для '#{slot_name}': #{formats[:text_color]} -> #{status_emoji}")
        end

        # Находим телеграм ник пользователя
        user = @user_registry.find_by_name(slot_name.strip)
        display_name = user&.username ? "@#{user.username}" : slot_name.strip

        slots_array << "#{status_emoji} #{display_name}"
      end
    end

    # Вспомогательный метод для форматирования текста слотов
    def format_slots_text(slots)
      if slots.all? { |s| s == "Отменен" }
        "Все слоты отменены"
      else
        slots.map.with_index do |slot, idx|
          if slot == "Отменен"
            "#{idx + 1}. 🚫 Отменен"
          elsif slot == "Свободно"
            "#{idx + 1}. ⚪ Свободно"
          else
            "#{idx + 1}. #{slot}"
          end
        end.join("\n")
      end
    end

    def cleanup_sent_notifications
      # Удаляем записи старше одного дня
      yesterday = @timezone.now - 86_400 # 24 часа
      @sent_notifications.delete_if { |_key, timestamp| timestamp < yesterday }
    end

    def send_game_notification_to_user(user, game, time_description, notification_type)
      return false unless @bot&.bot_instance && user&.telegram_id && user.sheet_name

      # Проверяем текущий статус участия
      current_status = get_user_current_attendance_status(user.sheet_name, game[:date])

      # Если пользователь уже отказался и это повторное уведомление, пропускаем отправку
      if current_status == "no" && notification_type != :final_reminder && current_status
        log(:info, "Пропуск повторного уведомления для #{user.display_name}: пользователь уже отказался")
        return false
      end

      # Устанавливаем флаг повторного уведомления
      is_reminder = current_status.nil? ? false : true

      # Определяем текстовое представление текущего статуса
      status_text = case current_status
                    when "yes"
                      "✅ Да (вы подтвердили участие)"
                    when "no"
                      "❌ Нет (вы отказались)"
                    when "maybe"
                      "🤔 Не уверен"
                    else
                      "⚪ Не указан"
                    end

      # Определяем текст сообщения в зависимости от типа и статуса
      if notification_type == :final_reminder
        # Для финального напоминания за два часа до игры используем другой текст
        message = <<~MESSAGE
          ⏰ *НАПОМИНАНИЕ*: Через час теннис!

          📅 Дата: *#{game[:date]}*
          🕒 Время: *#{game[:time]}*
          📍 Место: *#{game[:place]}*
        MESSAGE

        begin
          # Отправляем сообщение без кнопок для ответа
          @bot.bot_instance.api.send_message(
            chat_id: user.telegram_id,
            text: message,
            parse_mode: "Markdown"
          )
          return true
        rescue StandardError => e
          log(:error, "Ошибка при отправке уведомления за два часа для #{user.display_name}: #{e.message}")
        end
      else
        # Для остальных уведомлений - с кнопками для ответа
        if is_reminder
          # Для повторного уведомления используем специальное значение callback_data
          # в зависимости от текущего статуса пользователя
          yes_callback = if current_status == "yes"
                           "attendance:confirm_yes:#{game[:date]}"
                         elsif current_status == "no"
                           "attendance:confirm_no:#{game[:date]}"
                         elsif current_status == "maybe"
                           "attendance:confirm_maybe:#{game[:date]}"
                         else
                           "attendance:yes:#{game[:date]}"
                         end

          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "✅ Да",
                  callback_data: yes_callback # Вот здесь используем переменную yes_callback
                ),
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "❌ Нет",
                  # Добавляем специальный суффикс для обозначения повторного нажатия "нет"
                  callback_data: "attendance:no_reask:#{game[:date]}"
                )
              ]
            ]
          )

          message = <<~MESSAGE
            🎾 *НАПОМИНАНИЕ О ТЕННИСЕ* #{time_description}

            📅 Дата: *#{game[:date]}*
            🕒 Время: *#{game[:time]}*
            📍 Место: *#{game[:place]}*

            Ваш текущий статус: #{status_text}
            Подтверждаете статус?
          MESSAGE
        else
          # Для первого уведомления - стандартные три кнопки
          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "✅ Да",
                  callback_data: "attendance:yes:#{game[:date]}"
                ),
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "❌ Нет",
                  callback_data: "attendance:no:#{game[:date]}"
                ),
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "🤔 Не уверен",
                  callback_data: "attendance:maybe:#{game[:date]}"
                )
              ]
            ]
          )

          message = <<~MESSAGE
            🎾 *ПРИГЛАШЕНИЕ НА ТЕННИС* #{time_description}

            📅 Дата: *#{game[:date]}*
            🕒 Время: *#{game[:time]}*
            📍 Место: *#{game[:place]}*

            #{current_status ? "Ваш текущий статус: #{status_text}" : ""}
            Планируете ли вы прийти?
          MESSAGE
        end

        begin
          @bot.bot_instance.api.send_message(
            chat_id: user.telegram_id,
            text: message,
            parse_mode: "Markdown",
            reply_markup: keyboard
          )
          return true
        rescue StandardError => e
          log(:error, "Ошибка при отправке уведомления для #{user.display_name}: #{e.message}")
        end
      end

      false
    end

    def get_greeting_by_time
      current_hour = @timezone.now.hour

      case current_hour
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

    def send_today_notifications
      today_str = Date.today.strftime("%d.%m.%Y")
      players = get_today_players

      if players.empty?
        log(:info, "Игроки на сегодня (#{today_str}) не найдены")
        return
      end

      log(:info, "Найдено #{players.size} игроков на сегодня #{today_str}: #{players.join(", ")}")

      players.each do |player_name|
        user = @user_registry.find_by_name(player_name)
        if user
          send_notification_to_user(user, today_str)
        else
          log(:warn, "Telegram-пользователь для игрока не найден: #{player_name}")
        end
      end
    end

    def get_today_players
      today_str = Date.today.strftime("%d.%m.%Y")

      begin
        spreadsheet_data = @sheets_formatter.get_spreadsheet_data

        # Ищем строку на сегодня
        today_row = nil

        spreadsheet_data.each do |row|
          if row[0] == today_str
            today_row = row
            break
          end
        end

        return [] unless today_row

        # Получаем всех игроков (непустые ячейки из столбцов 3-10)
        # Столбцы: 0=дата, 1=время, 2=место, 3-6=с тренером, 7-10=без тренера
        today_row[3..10].compact.reject(&:empty?)
      rescue StandardError => e
        log(:error, "Ошибка при получении игроков на сегодня: #{e.message}")
        []
      end
    end

    def send_notification_to_user(user, date_str)
      log(:info, "Отправка уведомления для #{user.display_name} на #{date_str}")

      # Создаем клавиатуру с кнопками да/нет/не уверен
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "✅ Да",
              callback_data: "attendance:yes:#{date_str}"
            ),
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "❌ Нет",
              callback_data: "attendance:no:#{date_str}"
            ),
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "🤔 Не уверен",
              callback_data: "attendance:maybe:#{date_str}"
            )
          ]
        ]
      )

      # Отправляем сообщение с вопросом
      message = "Привет! Пойдёшь сегодня на теннис в #{@tennis_time}?"

      begin
        @bot.bot_instance.api.send_message(
          chat_id: user.telegram_id,
          text: message,
          reply_markup: keyboard
        )
        log(:info, "Уведомление успешно отправлено для #{user.display_name}")
      rescue Telegram::Bot::Exceptions::ResponseError => e
        log(:error, "Ошибка при отправке уведомления для #{user.display_name}: #{e.message}")
      end
    end

    def update_attendance_in_sheet(date_str, player_name, color)
      log(:info, "Начинаем обновление статуса для #{player_name} на #{date_str}")

      clean_player_name = player_name.strip

      sheet_name = Config.default_sheet_name
      log(:info, "Получаем данные листа #{sheet_name}")

      spreadsheet_data = @sheets_formatter.get_spreadsheet_data
      log(:info, "Получено #{spreadsheet_data.size} строк из таблицы")

      target_row_index = nil
      target_col_index = nil

      spreadsheet_data.each_with_index do |row, row_idx|
        log(:debug, "Проверяем строку #{row_idx}: #{row[0] || "пусто"}")
        next unless row[0] == date_str

        log(:info, "Нашли строку с датой #{date_str} (индекс: #{row_idx})")

        row.each_with_index do |cell, col_idx|
          next if col_idx < 3
          next unless cell

          log(:debug, "Проверяем ячейку [#{row_idx}, #{col_idx}]: '#{cell}' (длина: #{cell.length})")

          next unless cell.strip == clean_player_name

          target_row_index = row_idx
          target_col_index = col_idx
          log(:info, "Нашли ячейку игрока #{player_name} [#{row_idx}, #{col_idx}]: '#{cell}'")
          break
        end

        break if target_row_index
      end

      unless target_row_index && target_col_index
        log(:warn, "Не удалось найти ячейку для игрока '#{player_name}' на дату #{date_str}")
        return false
      end

      # Преобразуем в A1 нотацию
      col_letter = (target_col_index + "A".ord).chr
      cell_a1 = "#{col_letter}#{target_row_index + 1}"
      log(:info, "Ячейка для обновления: #{cell_a1}")

      # Применяем форматирование цвета текста вместо фона
      log(:info, "Применяем цвет текста #{color} к ячейке #{cell_a1}")
      @sheets_formatter.apply_format(sheet_name, cell_a1, :text_color, color)
      log(:info, "Обновлен статус посещения: #{player_name} на #{date_str} -> #{color}")

      true
    rescue StandardError => e
      log(:error, "Ошибка при обновлении статуса посещения: #{e.message}")
      log(:error, "Стек вызовов: #{e.backtrace.join("\n")}")
      false
    end

    def log(level, message)
      puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] [#{level.upcase}] [NotificationScheduler] #{message}"
    end
  end
end
