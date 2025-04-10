require 'date'
require 'time'
require 'tzinfo'

module SheetFormatterBot
  class NotificationScheduler
    attr_reader :bot, :sheets_formatter

    def initialize(bot:, sheets_formatter:)
      @bot = bot
      @sheets_formatter = sheets_formatter
      @user_registry = bot.user_registry
      @running = false
      @thread = nil

      # Загружаем конфигурацию из Config
      @hours_before = Config.notification_hours_before
      @tennis_time = Config.tennis_default_time
      @check_interval = Config.notification_check_interval
      @timezone = TZInfo::Timezone.get(Config.timezone || 'Asia/Yekaterinburg')
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

    # Метод для обработки ответов на уведомления
    def handle_attendance_callback(callback_query)
      data = callback_query.data
      _, response, date_str = data.split(':')

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

      # Обновляем цвет текста ячейки в таблице
      color = case response
              when 'yes' then 'green'
              when 'no' then 'red'
              when 'maybe' then 'yellow'
              end

      log(:info, "Имя в таблице: '#{sheet_name}', поиск ячейки для обновления...")

      if update_attendance_in_sheet(date_str, sheet_name, color)
        # Отправляем подтверждение
        message = case response
                  when 'yes' then "✅ Отлично! Ваш ответ 'Да' зарегистрирован."
                  when 'no' then "❌ Жаль! Ваш ответ 'Нет' зарегистрирован."
                  when 'maybe' then "🤔 Понятно. Ваш ответ 'Не уверен' зарегистрирован."
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

      # Используем более информативное тестовое сообщение
      current_hour = @timezone.now.hour
      greeting = get_greeting_by_time

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
        # Получаем текущее время в часовом поясе из конфигурации
        now = @timezone.now
        today = now.to_date
        tomorrow = today + 1

        log(:debug, "Проверка уведомлений на #{today}")

        # Проверяем предстоящие игры на сегодня и завтра
        check_games_and_notify(today, tomorrow, now)
      rescue StandardError => e
        log(:error, "Ошибка при проверке уведомлений: #{e.message}\n#{e.backtrace.join("\n")}")
      end
    end

    def check_games_and_notify(today, tomorrow, now)
      # Получаем данные из таблицы один раз для оптимизации
      spreadsheet_data = @sheets_formatter.get_spreadsheet_data

      # Получаем текущий час в часовом поясе пользователя
      current_hour = now.hour

      # Определяем часы уведомлений из конфигурации
      afternoon_hour = Config.morning_notification_hour # 13:00 (переименовано, но используем существующую переменную)
      evening_hour = Config.evening_notification_hour   # 18:00 (уже настроено в .env)

      # Проверяем игры на сегодня
      today_games = find_games_for_date(spreadsheet_data, today.strftime('%d.%m.%Y'))

      # Проверяем игры на завтра
      tomorrow_games = find_games_for_date(spreadsheet_data, tomorrow.strftime('%d.%m.%Y'))

      # Дневное уведомление (13:00) о сегодняшних и завтрашних играх
      if current_hour == afternoon_hour
        # Если есть игры сегодня
        if today_games.any?
          log(:info, "Отправляем дневное напоминание об играх сегодня (всего: #{today_games.count})")
          today_games.each do |game|
            send_notifications_for_game(game, "сегодня", "дневное")
          end
        end

        # Если есть игры завтра
        if tomorrow_games.any?
          log(:info, "Отправляем дневное напоминание об играх завтра (всего: #{tomorrow_games.count})")
          tomorrow_games.each do |game|
            send_notifications_for_game(game, "завтра", "дневное")
          end
        end
      end

      # Вечернее уведомление (18:00) о сегодняшних и завтрашних играх
      if current_hour == evening_hour
        # Если есть игры сегодня
        if today_games.any?
          log(:info, "Отправляем вечернее напоминание об играх сегодня (всего: #{today_games.count})")
          today_games.each do |game|
            send_notifications_for_game(game, "сегодня", "вечернее")
          end
        end

        # Если есть игры завтра
        if tomorrow_games.any?
          log(:info, "Отправляем вечернее напоминание об играх завтра (всего: #{tomorrow_games.count})")
          tomorrow_games.each do |game|
            send_notifications_for_game(game, "завтра", "вечернее")
          end
        end
      end

      # Напоминание за 1 час до игры (если включено)
      if Config.hour_before_notification
        if today_games.any?
          today_games.each do |game|
            # Парсим время игры
            game_hour, game_min = game[:time].split(':').map(&:to_i)

            # Проверяем, остался ли до игры 1 час
            hours_before = game_hour - current_hour
            if hours_before == 1 && game_min == 0 # Если игра в XX:00 и сейчас (XX-1):00
              log(:info, "Отправляем напоминание за час до игры в #{game[:time]}")
              send_notifications_for_game(game, "сегодня", "скорое")
            end
          end
        end
      end
    end

    def find_games_for_date(spreadsheet_data, date_str)
      games = []

      spreadsheet_data.each do |row|
        next unless row[0] == date_str

        time = row[1] || @tennis_time
        place = row[2] || "обычное место"

        # Получаем всех игроков (колонки 3-10)
        players = row[3..10].compact.reject(&:empty?)

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

      game[:players].each do |player_name|
        user = @user_registry.find_by_name(player_name)
        if user
          send_game_notification_to_user(user, game, time_description, notification_type)
        else
          log(:warn, "Telegram-пользователь для игрока не найден: #{player_name}")
        end
      end
    end

    def send_game_notification_to_user(user, game, time_description, notification_type)
      log(:info, "Отправка #{notification_type} уведомления для #{user.display_name} на #{game[:date]}")

      # Получаем приветствие в зависимости от времени суток
      greeting = get_greeting_by_time

      # Формируем сообщение в зависимости от типа уведомления
      message = case notification_type
      when "дневное"
        if time_description == "сегодня"
          "#{greeting}! Напоминаю, что сегодня у тебя теннис в #{game[:time]} в месте \"#{game[:place]}\". Будешь участвовать?"
        else # завтра
          "#{greeting}! Напоминаю, что завтра у тебя теннис в #{game[:time]} в месте \"#{game[:place]}\". Планируешь прийти?"
        end
      when "вечернее"
        if time_description == "сегодня"
          "#{greeting}! Напоминаю, что сегодня вечером у тебя теннис в #{game[:time]} в месте \"#{game[:place]}\". Подтверди своё участие."
        else # завтра
          "#{greeting}! Напоминаю, что завтра у тебя теннис в #{game[:time]} в месте \"#{game[:place]}\". Планируешь прийти?"
        end
      when "скорое"
        # Для уведомления за час до игры просто напоминание, без вопроса
        "⚠️ #{greeting}! Напоминаю, что теннис начнётся через час, в #{game[:time]} в месте \"#{game[:place]}\"."
      else
        "#{greeting}! #{time_description.capitalize} у тебя теннис в #{game[:time]} в месте \"#{game[:place]}\". Ты придёшь?"
      end

      # В зависимости от типа уведомления, выбираем - с кнопками или без
      if notification_type == "скорое"
        # Для уведомлений за час - без кнопок для ответа
        begin
          @bot.bot_instance.api.send_message(
            chat_id: user.telegram_id,
            text: message
          )
          log(:info, "Уведомление за час успешно отправлено для #{user.display_name}")
        rescue Telegram::Bot::Exceptions::ResponseError => e
          log(:error, "Ошибка при отправке уведомления за час для #{user.display_name}: #{e.message}")
        end
      else
        # Для остальных уведомлений - с кнопками для ответа
        # Создаем клавиатуру с кнопками да/нет/не уверен
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

        begin
          @bot.bot_instance.api.send_message(
            chat_id: user.telegram_id,
            text: message,
            reply_markup: keyboard
          )
          log(:info, "Уведомление с кнопками успешно отправлено для #{user.display_name}")
        rescue Telegram::Bot::Exceptions::ResponseError => e
          log(:error, "Ошибка при отправке уведомления для #{user.display_name}: #{e.message}")
        end
      end
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

        # Получаем всех игроков (непустые ячейки из столбцов 3-10)
        # Столбцы: 0=дата, 1=время, 2=место, 3-6=с тренером, 7-10=без тренера
        players = today_row[3..10].compact.reject(&:empty?)

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

        # Очищаем имя игрока от пробелов для более надежного сравнения
        clean_player_name = player_name.strip

        # Находим ячейку, где находится игрок для указанной даты
        sheet_name = Config.default_sheet_name
        log(:info, "Получаем данные листа #{sheet_name}")

        spreadsheet_data = @sheets_formatter.get_spreadsheet_data
        log(:info, "Получено #{spreadsheet_data.size} строк из таблицы")

        target_row_index = nil
        target_col_index = nil

        # Ищем строку с датой
        spreadsheet_data.each_with_index do |row, row_idx|
          log(:debug, "Проверяем строку #{row_idx}: #{row[0] || 'пусто'}")
          next unless row[0] == date_str

          log(:info, "Нашли строку с датой #{date_str} (индекс: #{row_idx})")

          # Ищем ячейку с именем игрока
          row.each_with_index do |cell, col_idx|
            next if col_idx < 3 # Пропускаем первые 3 столбца (дата, время, место)
            next unless cell # Пропускаем пустые ячейки

            log(:debug, "Проверяем ячейку [#{row_idx}, #{col_idx}]: '#{cell}' (длина: #{cell.length})")

            # Сравниваем с учетом возможных пробелов в конце
            if cell.strip == clean_player_name
              target_row_index = row_idx
              target_col_index = col_idx
              log(:info, "Нашли ячейку игрока #{player_name} [#{row_idx}, #{col_idx}]: '#{cell}'")
              break
            end
          end

          break if target_row_index
        end

        unless target_row_index && target_col_index
          log(:warn, "Не удалось найти ячейку для игрока '#{player_name}' на дату #{date_str}")
          return false
        end

        # Преобразуем в A1 нотацию
        col_letter = (target_col_index + 'A'.ord).chr
        cell_a1 = "#{col_letter}#{target_row_index + 1}"
        log(:info, "Ячейка для обновления: #{cell_a1}")

        # Применяем форматирование цвета текста вместо фона
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
