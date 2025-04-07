require 'date'
require 'time'

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
      sheet_name = user.sheet_name || user.display_name

      # Обновляем цвет текста ячейки в таблице
      color = case response
              when 'yes' then 'green'
              when 'no' then 'red'
              when 'maybe' then 'yellow'
              end

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
          text: "Произошла ошибка при обновлении данных."
        )
      end
    end

    # Метод для отправки тестового уведомления
    def send_test_notification(user, date_str)
      log(:info, "Отправка тестового уведомления для #{user.display_name}")

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
      message = "🧪 ТЕСТОВОЕ УВЕДОМЛЕНИЕ 🧪\n\nПривет! Пойдёшь сегодня на теннис в #{@tennis_time}?"

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
        # Получаем текущее время в часовом поясе Екатеринбурга
        now = @timezone.now
        today = now.to_date

        log(:debug, "Проверка уведомлений на #{today}")

        # Получаем текущее время
        now = Time.now

        # Парсим время начала тенниса на сегодня
        tennis_hour, tennis_min = @tennis_time.split(':').map(&:to_i)
        tennis_time = @timezone.local_time(now.year, now.month, now.day, tennis_hour, tennis_min)

        # Вычисляем, когда нужно отправить уведомление
        notification_time = tennis_time - (@hours_before * 60 * 60)

        # Определяем временное окно проверки (например, 15 минут)
        time_window_start = now
        time_window_end = now + @check_interval

        if notification_time >= time_window_start && notification_time <= time_window_end
          log(:info, "Пора отправлять уведомления о сегодняшнем теннисе в #{@tennis_time}")
          send_today_notifications
        else
          time_diff = (notification_time - now) / 60 # в минутах
          if time_diff > 0
            log(:debug, "Еще не время для уведомлений. Уведомления будут отправлены через #{time_diff.to_i} минут")
          else
            # Уже прошло время уведомления на сегодня
            log(:debug, "Время уведомлений на сегодня уже прошло")
          end
        end
      rescue StandardError => e
        log(:error, "Ошибка при проверке уведомлений: #{e.message}\n#{e.backtrace.join("\n")}")
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
            if cell.strip == player_name.strip
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
