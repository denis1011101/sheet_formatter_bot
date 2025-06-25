# frozen_string_literal: true

require "date"
require "time"
require "tzinfo"
require_relative "utils/slot_utils"
require_relative "utils/time_utils"
require_relative "utils/telegram_utils"
require_relative "utils/constants"

module SheetFormatterBot
  # For scheduling and sending notifications to users
  class NotificationScheduler
    include SheetFormatterBot::Utils::SlotUtils
    include SheetFormatterBot::Utils::TimeUtils
    include SheetFormatterBot::Utils::TelegramUtils
    include SheetFormatterBot::Utils::Constants

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
      begin
        # Получаем данные таблицы
        spreadsheet_data = @sheets_formatter.get_spreadsheet_data

        # Очищаем имя от лишних пробелов
        clean_player_name = sheet_name.strip

        # Проходим по данным и ищем ячейку с именем игрока
        spreadsheet_data.each_with_index do |row, row_idx|
          next unless row[0] == date_str  # Ищем только в строке с нужной датой

          # Проверяем ячейки в диапазоне, где могут быть имена игроков (колонки 3-15)
          (3..15).each do |col_idx|
            cell = row[col_idx].to_s

            # Сравниваем с учетом возможных пробелов в конце
            if cell.strip == clean_player_name
              # Проверяем цвет текста в этой ячейке
              col_letter = (col_idx + 'A'.ord).chr
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
        end

        # Не нашли имя игрока на указанную дату
        return nil
      rescue StandardError => e
        log(:error, "Ошибка при получении статуса посещения: #{e.message}")
        return nil
      end
    end

    # Метод для обработки ответов на уведомления
    def handle_attendance_callback(callback_query)
      data = callback_query.data
      _, response, date_str = data.split(':')

      # Проверяем, это подтверждение существующего статуса по префиксу
      is_explicit_confirmation = response.start_with?('confirm_')

      # Если это подтверждение, убираем префикс для дальнейшей обработки
      if is_explicit_confirmation
        orig_response = response
        response = response.sub('confirm_', '')
        log(:info, "Получено подтверждение статуса: #{orig_response} -> #{response}")
      end

      # Специальная обработка для "no_reask" - когда пользователь отвечает "Нет" на повторное уведомление
      if response == "no_reask"
        # Отправляем новое сообщение с тремя кнопками
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
            ]
          ]
        )

        message = <<~MESSAGE
          🎾 *ИЗМЕНЕНИЕ СТАТУСА УЧАСТИЯ*

          📅 Дата: *#{date_str}*

          Пожалуйста, выберите новый статус участия:
        MESSAGE

        begin
          # Убираем кнопки с исходного сообщения
          @bot.bot_instance.api.edit_message_reply_markup(
            chat_id: callback_query.message.chat.id,
            message_id: callback_query.message.message_id
          )

          # Отправляем новое сообщение с тремя вариантами
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

      return unless ['yes', 'no', 'maybe'].include?(response)

      telegram_id = callback_query.from.id
      user = @user_registry.find_by_telegram_id(telegram_id)

      unless user
        log(:warn, "Пользователь не найден для ID: #{telegram_id}")
        return
      end

      # Получаем имя пользователя в таблице
      sheet_name = user.sheet_name

      # Проверяем, что sheet_name существует
      unless sheet_name && !sheet_name.empty?
        log(:warn, "У пользователя #{user.display_name} не указано имя в таблице")
        @bot.bot_instance.api.answer_callback_query(
          callback_query_id: callback_query.id,
          text: "Ошибка: ваше имя не найдено в таблице. Укажите его через команду /myname или главное меню.",
          show_alert: true
        )
        return
      end

      # Получаем предыдущий статус
      previous_status = get_user_current_attendance_status(sheet_name, date_str)

      # ВАЖНАЯ ЧАСТЬ: Если это явное подтверждение или совпадение текущего/нового статуса - считаем это подтверждением
      is_confirmation = is_explicit_confirmation || (previous_status == response)
      is_changing = !is_confirmation && previous_status != nil

      log(:info, "Обработка ответа от #{user.display_name}: response=#{response}, previous=#{previous_status}, is_explicit_confirmation=#{is_explicit_confirmation}, is_confirmation=#{is_confirmation}")

      # Если это подтверждение - не обновляем таблицу
      should_update_sheet = !is_confirmation

      # Только если нужно обновить таблицу - получаем цвет и обновляем
      if should_update_sheet
        # Обновляем цвет текста ячейки в таблице
        color = STATUS_COLORS[response]

        log(:info, "Имя в таблице: '#{sheet_name}', поиск ячейки для обновления статуса на #{color}...")
        update_successful = update_attendance_in_sheet(date_str, sheet_name, color)
      else
        # Если это подтверждение - считаем операцию успешной без изменения таблицы
        log(:info, "Пользователь #{user.display_name} подтвердил текущий статус '#{response}' - таблица не обновляется")
        update_successful = true
      end

      # Отправляем подтверждение
      if update_successful || is_confirmation
        message = if is_confirmation
                    case response
                    when 'yes'
                      "✅ Спасибо за подтверждение! Ждём вас на игре."
                    when 'no'
                      "❌ Вы подтвердили свой отказ от участия."
                    when 'maybe'
                      "🤔 Вы подтвердили свой статус 'Не уверен'."
                    end
                  else
                    case response
                    when 'yes'
                      if is_changing && previous_status
                        "✅ Вы изменили свой ответ на 'Да'. Будем ждать вас на игре!"
                      else
                        "✅ Отлично! Ваш ответ 'Да' зарегистрирован."
                      end
                    when 'no'
                      if is_changing && previous_status
                        "❌ Вы изменили свой ответ на 'Нет'. Жаль, что не сможете прийти."
                      else
                        "❌ Жаль! Ваш ответ 'Нет' зарегистрирован."
                      end
                    when 'maybe'
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
    end

    # Метод для отправки тестового уведомления
    def send_test_notification(user, date_str)
      log(:info, "Отправка тестового уведомления для #{user.display_name}")

      greeting = greeting_by_hour(@timezone.now.hour)

      # Создаем клавиатуру с кнопками да/нет/не уверен
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
          ]
        ]
      )

      # Отправляем тестовое сообщение с вопросом
      message = "🧪 ТЕСТОВОЕ УВЕДОМЛЕНИЕ 🧪\n\n#{greeting}! Сегодня у тебя теннис в #{@tennis_time} в обычном месте. Планируешь прийти?"

      begin
        @bot.bot_instance.api.send_message(
          chat_id: user.telegram_id,
          text: message,
          reply_markup: keyboard
        )
        log(:info, "Тестовое уведомление успешно отправлено для #{user.display_name}")
        return true
      rescue Telegram::Bot::Exceptions::ResponseError => e
        log(:error, "Ошибка при отправке тестового уведомления для #{user.display_name}: #{e.message}")
        return false
      end
    end

    private

    def scheduler_loop
      while @running
        check_and_send_notifications
        # Спим указанный в конфигурации интервал
        sleep(@check_interval)
      end
    end

    def check_and_send_notifications
      begin
        # Периодически очищаем старые записи об отправленных уведомлениях
        cleanup_sent_notifications

        # Получаем текущее время в часовом поясе из конфигурации
        now = @timezone.now
        today = now.to_date
        tomorrow = today + 1

        log(:debug, "Проверка уведомлений на #{today}")

        # Получаем данные из таблицы один раз для оптимизации
        begin
          spreadsheet_data = @sheets_formatter.get_spreadsheet_data
        rescue StandardError => e
          log(:error, "Не удалось получить данные из Google Sheets: #{e.message}")
          # Просто пропускаем эту итерацию, попробуем в следующий раз
          return
        end

        # Получаем текущий час в часовом поясе пользователя
        current_hour = now.hour
        current_minute = now.min

        # Определяем часы уведомлений из конфигурации
        personal_afternoon_hour = Config.personal_morning_notification_hour
        personal_evening_hour = Config.personal_evening_notification_hour
        group_afternoon_hour = Config.group_morning_notification_hour
        group_evening_hour = Config.group_evening_notification_hour
        final_reminder_hour = Config.final_reminder_notification_hour
        admin_reminder_hour = Config.admin_reminder_hour
        admin_reminder_wday = Config.admin_reminder_wday

        # Проверяем игры на сегодня
        today_games = find_games_for_date(spreadsheet_data, today.strftime('%d.%m.%Y'))

        # Проверяем игры на завтра
        tomorrow_games = find_games_for_date(spreadsheet_data, tomorrow.strftime('%d.%m.%Y'))

        # Если все игры на сегодня уже начались или прошли — выходим из функции
        all_games_finished = today_games.all? do |game|
          game_hour = parse_game_hour(game[:time])
          game_hour && current_hour >= game_hour
        end

        if today_games.any? && all_games_finished
          log(:info, "Все игры на сегодня уже начались или прошли — уведомления не отправляются")
          return
        end

        admin_ids = Config.admin_telegram_ids
        if today.wday == admin_reminder_wday && current_hour == admin_reminder_hour && !@sent_notifications["admin_friday_reminder:#{today}"]
          admin_ids.each do |admin_id|
            @bot.bot_instance.api.send_message(
              chat_id: admin_id,
              text: "⏰ Пятница! Не забудьте забронировать корт и тренера Артёма на следующую неделю.",
              parse_mode: "Markdown"
            )
          end
          @sent_notifications["admin_friday_reminder:#{today}"] = Time.now
          log(:info, "Отправлено пятничное напоминание администраторам о бронировании корта и тренера Артёма")
        end

        # Дневное личное уведомление о сегодняшних и завтрашних играх
        if current_hour == personal_afternoon_hour
          # Если есть игры сегодня
          if today_games.any?
            log(:info, "Отправляем дневное личное напоминание об играх сегодня (всего: #{today_games.count})")
              today_games.each do |game|
              game_hour = parse_game_hour(game[:time])
              # Пропускаем, если игра уже началась или прошла
              next if game_hour && current_hour >= game_hour
              send_notifications_for_game(game, "сегодня", "дневное")
            end
          end

          # Если есть игры завтра
          if tomorrow_games.any?
            log(:info, "Отправляем дневное личное напоминание об играх завтра (всего: #{tomorrow_games.count})")
            tomorrow_games.each do |game|
              send_notifications_for_game(game, "завтра", "дневное")
            end
          end
        end

        # Вечернее личное уведомление о сегодняшних и завтрашних играх
        if current_hour == personal_evening_hour
          # Если есть игры сегодня
          if today_games.any?
            log(:info, "Отправляем вечернее личное напоминание об играх сегодня (всего: #{today_games.count})")
            today_games.each do |game|
              game_hour = parse_game_hour(game[:time])
              next if game_hour && current_hour >= game_hour
              send_notifications_for_game(game, "сегодня", "вечернее")
            end
          end


          # Если есть игры завтра
          if tomorrow_games.any?
            log(:info, "Отправляем вечернее личное напоминание об играх завтра (всего: #{tomorrow_games.count})")
            tomorrow_games.each do |game|
              send_notifications_for_game(game, "завтра", "вечернее")
            end
          end
        end

        # Вечернее уведомление в общий чат
        if current_hour == group_evening_hour
          # Уведомление за день до игры
          if tomorrow_games.any?
            log(:info, "Отправляем вечернее уведомление в общий чат о завтрашних играх")
            tomorrow_games.each do |game|
              send_general_chat_notification(game, "завтра")
            end
          end
        end

        # Финальное напоминание перед игрой в указанное время
        if final_reminder_hour && today_games.any?
          # Создаём уникальный ключ для проверки отправки финального напоминания
          final_reminder_key = "final_reminder:#{today.strftime('%Y-%m-%d')}"

          # Проверяем текущий час и отправлялось ли уже напоминание сегодня
          if current_hour == final_reminder_hour && !@sent_notifications[final_reminder_key]
            log(:info, "Отправляем финальное напоминание об играх сегодня (всего: #{today_games.count})")
            today_games.each do |game|
              game_hour = parse_game_hour(game[:time])
              next if game_hour && current_hour >= game_hour
              send_notifications_for_game(game, "сегодня", :final_reminder)
            end
            @sent_notifications[final_reminder_key] = Time.now
          end
        end
      rescue StandardError => e
        log(:error, "Ошибка при проверке уведомлений: #{e.message}\n#{e.backtrace.join("\n")}")
      end
    end

    def find_games_for_date(spreadsheet_data, date_str)
      games = []

      spreadsheet_data.each do |row|
        next unless row[0] == date_str

        time = row[1] || @tennis_time
        place = row[2] || "обычное место"

        # Получаем всех игроков (колонки 3-15)
        players = row[3..15].compact.reject(&:empty?).reject { |name| IGNORED_SLOT_NAMES.include?(name.strip.downcase) }

        games << {
          date: date_str,
          time: time,
          place: place,
          players: players
        }
      end

      games
    end

    def send_notifications_for_game(game, time_description, notification_type)
      log(:info, "Отправляем #{notification_type} уведомление о игре #{time_description} в #{game[:time]}")

      # Уникальный ключ для этой рассылки
      today = @timezone.now.to_date.strftime('%Y-%m-%d')
      notification_key = "personal:#{today}:#{game[:date]}:#{time_description}"

      # Если на сегодня такие уведомления уже отправлялись, пропускаем
      if @sent_notifications[notification_key]
        log(:info, "Уведомления #{notification_type} для игры #{game[:date]} (#{time_description}) уже были отправлены сегодня")
        return
      end

      players_notified = 0

      # Отправляем уведомления только реальным игрокам (не "отмена")
      game[:players].each do |player_name|
        clean_name = player_name.strip.downcase
        next if IGNORED_SLOT_NAMES.include?(clean_name)

        user = @user_registry.find_by_name(player_name)
        if user
          # Добавляем небольшую случайную задержку (от 0.8 до 2.5 секунды) между сообщениями
          # чтобы избежать слишком частых запросов к Telegram API
          sleep(rand(0.8..2.5)) if players_notified > 0

          send_game_notification_to_user(user, game, time_description, notification_type)
          players_notified += 1

          log(:debug, "Отправлено уведомление #{players_notified}/#{game[:players].size}, сделана пауза")
        else
          log(:warn, "Telegram-пользователь для игрока не найден: #{player_name}")
        end
      end

      # Отмечаем, что уведомления отправлены (только если были отправлены хотя бы 1)
      @sent_notifications[notification_key] = Time.now if players_notified > 0

      log(:info, "Отправка уведомлений завершена, отправлено #{players_notified} сообщений")
    end

    def send_general_chat_notification(game, time_description)
      general_chat_id = Config.general_chat_id
      return unless general_chat_id # Если ID общего чата не указан, ничего не делаем

      # Создаем уникальный ключ для отслеживания отправленных уведомлений в общий чат
      today = @timezone.now.to_date.strftime('%Y-%m-%d')
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
        if row[0] == game[:date]
          full_row_data = row
          row_idx = idx + 1 # +1 потому что индексация в A1 нотации начинается с 1
          break
        end
      end

      return unless full_row_data

      log(:info, "Найдена строка для даты #{game[:date]}, индекс строки: #{row_idx}")

      # Формируем массивы для слотов
      slots_with_trainer = []
      slots_without_trainer = []

      # Анализируем слоты с тренером (колонки 3-6) (индекс с нуля)
      process_slots(full_row_data, 3..6, slots_with_trainer, row_idx)

      # Анализируем слоты без тренера (колонки 7-10)
      process_slots(full_row_data, 7..10, slots_without_trainer, row_idx)

      # Проверяем дополнительные слоты (колонки 11 и далее)
      if full_row_data.length > 11
        # Дополнительные слоты (после 10-й колонки)
        (11...full_row_data.length).each do |i|
          if full_row_data[i] && !full_row_data[i].strip.empty?
            # Проверяем, не является ли это примечанием или служебной информацией
            # Типично примечания содержат слова "забронировано", "корт", и т.п.
            cell_content = full_row_data[i].strip.downcase
            is_note = cell_content.include?("забронен") ||
                      cell_content.include?("корт") ||
                      cell_content.include?("примечание")

            next if IGNORED_SLOT_NAMES.include?(cell_content)

            unless is_note
              # Получаем формат ячейки для определения статуса
              col_letter = (i + 'A'.ord).chr
              cell_a1 = "#{col_letter}#{row_idx}"
              formats = @sheets_formatter.get_cell_formats(Config.default_sheet_name, cell_a1)

              # Определяем статус по цвету текста
              status_emoji = "⚪" # По умолчанию - нет статуса

              if formats && formats[:text_color]
                case formats[:text_color]
                when "green"
                  status_emoji = "✅"
                when "red"
                  status_emoji = "❌"
                when "yellow"
                  status_emoji = "🤔"
                end
              end

              # Находим телеграм ник пользователя
              user = @user_registry.find_by_name(full_row_data[i].strip)
              display_name = user&.username ? "@#{user.username}" : full_row_data[i].strip

              # Добавляем в список слотов без тренера
              slots_without_trainer << "#{status_emoji} #{display_name}"
            end
          end
        end
      end

      # Формируем текст для слотов
      slots_with_trainer_text =
        if slots_with_trainer.size == 4 && slots_with_trainer.all? { |s| slot_cancelled?(s) }
          "Все слоты отменены"
        else
          format_slots_text(slots_with_trainer)
        end

      slots_without_trainer_text =
        if slots_without_trainer.size == 4 && slots_without_trainer.all? { |s| slot_cancelled?(s) }
          "Все слоты отменены"
        else
          format_slots_text(slots_without_trainer)
        end

      if slots_with_trainer_text == "Все слоты отменены" && slots_without_trainer_text == "Все слоты отменены"
        log(:info, "Все слоты отменены на #{game[:date]} - уведомление не отправляется")
        return
      end

      # Определяем, все ли места заняты
      slots_with_trainer_cancelled = slots_with_trainer.size == 4 && slots_with_trainer.all? { |s| slot_cancelled?(s) }
      slots_without_trainer_cancelled = slots_without_trainer.size == 4 &&
                                        slots_without_trainer.all? { |s| slot_cancelled?(s) }

      slots_with_trainer_available = !slots_with_trainer_cancelled && slots_with_trainer.any? { |s| s == "Свободно" }
      slots_without_trainer_available = !slots_without_trainer_cancelled &&
                                        slots_without_trainer.any? { |s| s == "Свободно" }

      all_slots_busy = !slots_with_trainer_available &&
                       !slots_without_trainer_available &&
                       !slots_with_trainer_cancelled &&
                       !slots_without_trainer_cancelled

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
      MESSAGE

      # Добавляем информацию о возможности записи
      message += <<~MESSAGE

        #{all_slots_busy ? "Все места заняты!" : "Есть свободные места!"}
        #{all_slots_busy ? "Изменить статус участия можно через бота: @#{safe_username}" : "Записаться на игру можно через бота: @#{safe_username}"}
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

    # Вспомогательный метод для обработки слотов
    def process_slots(row_data, range, slots_array, row_idx)
      range.each do |i|
        slot_name = row_data[i]
        clean_name = slot_name&.strip&.downcase

        if slot_name.nil? || slot_name.strip.empty?
          slots_array << "Свободно"
          next
        end

        # Если это отмена — "Отменен"
        if CANCELLED_SLOT_NAMES.include?(clean_name)
          slots_array << "Отменен"
          next
        end

        # Если это техническое значение (но не отмена) — "Свободно"
        if IGNORED_SLOT_NAMES.include?(clean_name)
          slots_array << "Свободно"
          next
        end

        # Получаем формат ячейки для определения статуса
        col_letter = (i + 'A'.ord).chr
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

    def cleanup_sent_notifications
      # Удаляем записи старше одного дня
      yesterday = @timezone.now - 86400 # 24 часа
      @sent_notifications.delete_if { |_key, timestamp| timestamp < yesterday }
    end

    def send_game_notification_to_user(user, game, time_description, notification_type)
      return false unless @bot&.bot_instance && user&.telegram_id && user&.sheet_name

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
                    when STATUS_YES
                      "✅ Да (вы подтвердили участие)"
                    when STATUS_NO
                      "❌ Нет (вы отказались)"
                    when STATUS_MAYBE
                      "🤔 Не уверен"
                    else
                      "⚪ Не указан"
                    end

      # Определяем текст сообщения в зависимости от типа и статуса
      if notification_type == :final_reminder

        # Создаем время в нужном часовом поясе
        game_time = parse_game_time(game[:date], game[:time], @timezone)
        current_time = @timezone.now
        time_diff_hours = hours_diff(game_time, current_time)

        # Формируем текст в зависимости от времени до игры
        time_text = case time_diff_hours
                    when 0
                      "Теннис начинается!"
                    when 1
                      "Через час теннис!"
                    when 2
                      "Через 2 часа теннис!"
                    when 3..5
                      "Через #{time_diff_hours} часа теннис!"
                    else
                      "Через #{time_diff_hours} часов теннис!"
                    end

        message = <<~MESSAGE
          ⏰ *НАПОМИНАНИЕ*: #{time_text}

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
          if current_status == "yes"
            yes_callback = "attendance:confirm_yes:#{game[:date]}"
          elsif current_status == "no"
            yes_callback = "attendance:confirm_no:#{game[:date]}"
          elsif current_status == "maybe"
            yes_callback = "attendance:confirm_maybe:#{game[:date]}"
          else
            yes_callback = "attendance:yes:#{game[:date]}"
          end

          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: '✅ Да',
                  callback_data: yes_callback
                ),
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: '❌ Нет',
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

    def send_today_notifications
      today_str = Date.today.strftime('%d.%m.%Y')
      players = get_today_players

      if players.empty?
        log(:info, "Игроки на сегодня (#{today_str}) не найдены")
        return
      end

      log(:info, "Найдено #{players.size} игроков на сегодня #{today_str}: #{players.join(', ')}")

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
      today_str = Date.today.strftime('%d.%m.%Y')

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

        # Получаем всех игроков (непустые ячейки из столбцов 3-15) (индекс с нуля)
        # Столбцы: 0=дата, 1=время, 2=место, 3-6=с тренером, 7-15=без тренера
        players = today_row[3..15].compact.reject(&:empty?)

        return players
      rescue StandardError => e
        log(:error, "Ошибка при получении игроков на сегодня: #{e.message}")
        return []
      end
    end

    def send_notification_to_user(user, date_str)
      log(:info, "Отправка уведомления для #{user.display_name} на #{date_str}")

      # Создаем клавиатуру с кнопками да/нет/не уверен
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
      begin
        log(:info, "Начинаем обновление статуса для #{player_name} на #{date_str}")

        clean_player_name = player_name.strip

        sheet_name = Config.default_sheet_name
        log(:info, "Получаем данные для даты #{date_str}")

        target_date_data = @sheets_formatter.get_spreadsheet_data_for_dates([date_str])

        if target_date_data.empty?
          log(:warn, "Не найдена строка с датой #{date_str}")
          return false
        end

        target_row = target_date_data[0]
        log(:info, "Найдена строка с датой #{date_str}")

        full_data = @sheets_formatter.get_spreadsheet_data
        target_row_index = full_data.index(target_row)

        unless target_row_index
          log(:warn, "Не удалось определить индекс строки для даты #{date_str}")
          return false
        end

        target_col_index = nil

        target_row.each_with_index do |cell, col_idx|
          next if col_idx < 3
          next unless cell

          log(:debug, "Проверяем ячейку [#{target_row_index}, #{col_idx}]: '#{cell}' (длина: #{cell.length})")

          if cell.strip == clean_player_name
            target_col_index = col_idx
            log(:info, "Нашли ячейку игрока #{player_name} [#{target_row_index}, #{col_idx}]: '#{cell}'")
            break
          end
        end

        unless target_col_index
          log(:warn, "Не удалось найти ячейку для игрока '#{player_name}' на дату #{date_str}")
          return false
        end

        col_letter = (target_col_index + 'A'.ord).chr
        cell_a1 = "#{col_letter}#{target_row_index + 1}"
        log(:info, "Ячейка для обновления: #{cell_a1}")

        log(:info, "Применяем цвет текста #{color} к ячейке #{cell_a1}")
        @sheets_formatter.apply_format(sheet_name, cell_a1, :text_color, color)
        log(:info, "Обновлен статус посещения: #{player_name} на #{date_str} -> #{color}")

        return true
      rescue StandardError => e
        log(:error, "Ошибка при обновлении статуса посещения: #{e.message}")
        log(:error, "Стек вызовов: #{e.backtrace.join("\n")}")
        return false
      end
    end

    def log(level, message)
      puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] [#{level.upcase}] [NotificationScheduler] #{message}"
    end
  end
end
