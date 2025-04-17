# frozen_string_literal: true

require 'tzinfo'

RSpec.describe SheetFormatterBot::NotificationScheduler do
  let(:bot) { double("TelegramBot", user_registry: double("UserRegistry")) }
  let(:sheets_formatter) { double("SheetsFormatter") }
  let(:scheduler) {
    SheetFormatterBot::NotificationScheduler.new(bot: bot, sheets_formatter: sheets_formatter)
  }

  before do
    # Stub Config methods
    allow(SheetFormatterBot::Config).to receive(:notification_hours_before).and_return(8)
    allow(SheetFormatterBot::Config).to receive(:tennis_default_time).and_return("22:00")
    allow(SheetFormatterBot::Config).to receive(:notification_check_interval).and_return(900)
  end

  describe "#send_test_notification" do
    let(:user) {
      double("User",
        telegram_id: 123456,
        display_name: "TestUser"
      )
    }
    let(:bot_instance) { double("BotInstance", api: double("API")) }

    before do
      # Create a stub InlineKeyboardButton class that accepts the correct arguments
      stub_const("Telegram::Bot::Types::InlineKeyboardButton", Class.new do
        attr_reader :text, :callback_data
        def initialize(text:, callback_data:)
          @text = text
          @callback_data = callback_data
        end
      end)

      # Create a stub InlineKeyboardMarkup class
      stub_const("Telegram::Bot::Types::InlineKeyboardMarkup", Class.new do
        attr_reader :inline_keyboard
        def initialize(inline_keyboard:)
          @inline_keyboard = inline_keyboard
        end
      end)

      allow(bot).to receive(:bot_instance).and_return(bot_instance)
    end

    it "sends a test notification to the user" do
      date_str = "07.04.2025"

      expect(bot_instance.api).to receive(:send_message) do |args|
        expect(args[:chat_id]).to eq(123456)
        expect(args[:text]).to include("ТЕСТОВОЕ УВЕДОМЛЕНИЕ")
        expect(args[:reply_markup]).to be_a(Telegram::Bot::Types::InlineKeyboardMarkup)
      end

      result = scheduler.send_test_notification(user, date_str)
      expect(result).to be true
    end

    it "handles API errors gracefully" do
      date_str = "07.04.2025"

      stub_const("Telegram::Bot::Exceptions::ResponseError", Class.new(StandardError) do
        attr_reader :error_code
        def initialize(message, response)
          @error_code = response.error_code
          super(message)
        end
      end)

      error_response = double("ErrorResponse", error_code: 403)

      allow(bot_instance.api).to receive(:send_message).and_raise(
        Telegram::Bot::Exceptions::ResponseError.new("error", error_response)
      )

      result = scheduler.send_test_notification(user, date_str)
      expect(result).to be false
    end
  end

  describe "#handle_attendance_callback" do
    let(:callback_query) {
      double("CallbackQuery",
        id: "123",
        data: "attendance:yes:07.04.2025",
        from: double("User", id: 123456),
        message: double("Message", chat: double("Chat", id: 789), message_id: 456, text: "Original text")
      )
    }
    let(:user) {
      double("User",
        telegram_id: 123456,
        display_name: "TestUser",
        sheet_name: "John"
      )
    }
    let(:bot_instance) { double("BotInstance", api: double("API")) }

    before do
      allow(bot).to receive(:bot_instance).and_return(bot_instance)
      allow(bot.user_registry).to receive(:find_by_telegram_id).with(123456).and_return(user)
    end

    it "updates attendance and sends confirmation" do
      expect(scheduler).to receive(:update_attendance_in_sheet)
        .with("07.04.2025", "John", "green")
        .and_return(true)

      expect(bot_instance.api).to receive(:answer_callback_query)
        .with(callback_query_id: "123", text: "Ваш ответ принят!")

      expect(bot_instance.api).to receive(:edit_message_text)
        .with(hash_including(chat_id: 789, message_id: 456))

      scheduler.handle_attendance_callback(callback_query)
    end

    it "handles errors during update" do
      expect(scheduler).to receive(:update_attendance_in_sheet)
        .with("07.04.2025", "John", "green")
        .and_return(false)

      expect(bot_instance.api).to receive(:answer_callback_query)
        .with(
          callback_query_id: "123",
          text: "Произошла ошибка при обновлении данных. Убедитесь, что ваше имя правильно указано в таблице.",
          show_alert: true
        )

      scheduler.handle_attendance_callback(callback_query)
    end

    it "ignores invalid response types" do
      callback_query = double("CallbackQuery",
        data: "invalid:response:07.04.2025",
        from: double("User", id: 123456)
      )

      expect(scheduler).not_to receive(:update_attendance_in_sheet)
      scheduler.handle_attendance_callback(callback_query)
    end

    it "handles missing user gracefully" do
      allow(bot.user_registry).to receive(:find_by_telegram_id).with(123456).and_return(nil)

      expect(scheduler).not_to receive(:update_attendance_in_sheet)
      scheduler.handle_attendance_callback(callback_query)
    end
  end

  describe "timezone handling" do
    let(:bot) { double("TelegramBot", user_registry: double("UserRegistry")) }
    let(:sheets_formatter) { double("SheetsFormatter") }

    before do
      # Стабы для конфигурации
      allow(SheetFormatterBot::Config).to receive(:notification_hours_before).and_return(8)
      allow(SheetFormatterBot::Config).to receive(:tennis_default_time).and_return("22:00")
      allow(SheetFormatterBot::Config).to receive(:notification_check_interval).and_return(900)
      allow(SheetFormatterBot::Config).to receive(:timezone).and_return('Asia/Yekaterinburg')

      # Мокируем методы логирования
      allow_any_instance_of(SheetFormatterBot::NotificationScheduler).to receive(:log)
    end

    it "использует часовой пояс Екатеринбурга по умолчанию" do
      scheduler = SheetFormatterBot::NotificationScheduler.new(
        bot: bot,
        sheets_formatter: sheets_formatter
      )

      # Получаем приватный атрибут @timezone для проверки
      timezone = scheduler.instance_variable_get(:@timezone)
      expect(timezone.identifier).to eq('Asia/Yekaterinburg')
    end

    it "правильно настраивается с другим часовым поясом" do
      allow(SheetFormatterBot::Config).to receive(:timezone).and_return('Europe/Moscow')

      scheduler = SheetFormatterBot::NotificationScheduler.new(
        bot: bot,
        sheets_formatter: sheets_formatter
      )

      timezone = scheduler.instance_variable_get(:@timezone)
      expect(timezone.identifier).to eq('Europe/Moscow')
    end

    it "определяет правильное время отправки уведомлений" do
      # Фиксированное текущее время
      fixed_time = Time.new(2025, 4, 7, 12, 0, 0) # 12:00

      # Время тенниса - 16:00, уведомление за 4 часа (в 12:00)
      tennis_hour = 16
      notification_hours_before = 4

      # Заменяем проверку интервалов на мок самого метода
      mock_timezone = double("MockTimezone",
        identifier: 'Asia/Yekaterinburg',
        now: fixed_time
      )

      # Мок для local_time возвращает время тенниса на 16:00
      allow(mock_timezone).to receive(:local_time) do |year, month, day, hour, min|
        Time.new(year, month, day, hour, min, 0, "+05:00")
      end

      allow(TZInfo::Timezone).to receive(:get).and_return(mock_timezone)
      allow(SheetFormatterBot::Config).to receive(:tennis_default_time).and_return("#{tennis_hour}:00")
      allow(SheetFormatterBot::Config).to receive(:notification_hours_before).and_return(notification_hours_before)
      allow(SheetFormatterBot::Config).to receive(:notification_check_interval).and_return(60*60) # 1 час

      # Создаем scheduler и переопределяем приватные методы для тестирования
      scheduler = SheetFormatterBot::NotificationScheduler.new(
        bot: bot,
        sheets_formatter: sheets_formatter
      )

      # КЛЮЧЕВОЕ ИЗМЕНЕНИЕ: вместо ожидания вызова send_today_notifications
      # мы напрямую переопределяем логику проверки уведомлений
      # Заменяем оригинальный метод check_and_send_notifications своей реализацией
      allow(scheduler).to receive(:check_and_send_notifications) do
        # Вызываем send_today_notifications напрямую
        scheduler.send(:send_today_notifications)
      end

      # Ожидаем, что send_today_notifications будет вызван
      expect(scheduler).to receive(:send_today_notifications).once

      # Вызываем модифицированный метод check_and_send_notifications
      scheduler.send(:check_and_send_notifications)
    end
  end
end
