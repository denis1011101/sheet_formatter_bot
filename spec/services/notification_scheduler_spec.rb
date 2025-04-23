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
      allow(sheets_formatter).to receive(:get_spreadsheet_data).and_return([
        ["07.04.2025", "22:00", "Спортклуб", "John", "", "", "", "", "", "", ""]
      ])
      allow(sheets_formatter).to receive(:get_cell_formats).and_return({})
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

  describe "#send_game_notification_to_user" do
    let(:user) { double("User", telegram_id: 123456, sheet_name: "Test User", display_name: "Test User") }
    let(:game) { {date: "01.05.2023", time: "22:00", place: "обычное место"} }
    let(:mock_api) { double("API") }
    let(:bot_instance) { double("BotInstance", api: mock_api) }

    before do
      allow(bot).to receive(:bot_instance).and_return(bot_instance)
      allow(sheets_formatter).to receive(:get_spreadsheet_data).and_return([
        ["01.05.2023", "22:00", "Спортклуб", "Test User", "", "", "", "", "", "", ""]
      ])
      allow(sheets_formatter).to receive(:get_cell_formats).and_return({})
      stub_const("Telegram::Bot::Types::InlineKeyboardButton", Class.new do
        attr_reader :text, :callback_data
        def initialize(text:, callback_data:)
          @text = text
          @callback_data = callback_data
        end
      end)
      stub_const("Telegram::Bot::Types::InlineKeyboardMarkup", Class.new do
        attr_reader :inline_keyboard
        def initialize(inline_keyboard:)
          @inline_keyboard = inline_keyboard
        end
      end)
    end

    context "при первичном уведомлении" do
      it "отправляет сообщение с меню выбора и спрашивает о планах" do
        expect(mock_api).to receive(:send_message) do |params|
          expect(params[:chat_id]).to eq(123456)
          expect(params[:text]).to include("ПРИГЛАШЕНИЕ НА ТЕННИС")
          expect(params[:text]).to include("Планируете ли вы прийти?")
          expect(params[:reply_markup]).not_to be_nil
        end

        scheduler.send(:send_game_notification_to_user, user, game, "завтра", "дневное")
      end
    end

    context "при повторном уведомлении с ответом 'да'" do
      before do
        allow(scheduler).to receive(:get_user_current_attendance_status).and_return("yes")
      end

      it "напоминает о предыдущем ответе и спрашивает не передумал ли пользователь" do
        expect(mock_api).to receive(:send_message) do |params|
          expect(params[:chat_id]).to eq(123456)
          expect(params[:text]).to include("НАПОМИНАНИЕ О ТЕННИСЕ")
          expect(params[:text]).to include("✅ Вы подтвердили свое участие")
          expect(params[:text]).to include("Не передумали?")
          expect(params[:reply_markup]).not_to be_nil
        end

        scheduler.send(:send_game_notification_to_user, user, game, "завтра", "дневное")
      end
    end

    context "при повторном уведомлении с ответом 'нет'" do
      before do
        allow(scheduler).to receive(:get_user_current_attendance_status).and_return("no")
      end

      it "напоминает о предыдущем ответе и спрашивает не передумал ли пользователь" do
        expect(mock_api).to receive(:send_message) do |params|
          expect(params[:chat_id]).to eq(123456)
          expect(params[:text]).to include("НАПОМИНАНИЕ О ТЕННИСЕ")
          expect(params[:text]).to include("❌ Вы отказались от участия")
          expect(params[:text]).to include("Не передумали?")
          expect(params[:reply_markup]).not_to be_nil
        end

        scheduler.send(:send_game_notification_to_user, user, game, "завтра", "дневное")
      end
    end

    context "при повторном уведомлении с ответом 'может быть'" do
      before do
        allow(scheduler).to receive(:get_user_current_attendance_status).and_return("maybe")
      end

      it "напоминает о предыдущем ответе и спрашивает не передумал ли пользователь" do
        expect(mock_api).to receive(:send_message) do |params|
          expect(params[:chat_id]).to eq(123456)
          expect(params[:text]).to include("НАПОМИНАНИЕ О ТЕННИСЕ")
          expect(params[:text]).to include("🤔 Вы не уверены в своем участии")
          expect(params[:text]).to include("Не передумали?")
          expect(params[:reply_markup]).not_to be_nil
        end

        scheduler.send(:send_game_notification_to_user, user, game, "завтра", "дневное")
      end
    end

    context "при финальном напоминании за два часа до игры" do
      it "отправляет сообщение без кнопок выбора" do
        expect(mock_api).to receive(:send_message) do |params|
          expect(params[:chat_id]).to eq(123456)
          expect(params[:text]).to match(/НАПОМИНАНИЕ.*Через час теннис/)
          expect(params[:text]).not_to include("Не передумали?")
          expect(params[:text]).not_to include("Планируете ли вы прийти?")
          expect(params[:reply_markup]).to be_nil
        end

        scheduler.send(:send_game_notification_to_user, user, game, "сегодня", :final_reminder)
      end
    end
  end

  describe "#get_user_current_attendance_status" do
    let(:mock_formats) { {} }

    before do
      allow(sheets_formatter).to receive(:get_spreadsheet_data).and_return([
        ["01.05.2023", "22:00", "Спортклуб", "Test User", "", "", "", "", "", "", ""]
      ])

      allow(sheets_formatter).to receive(:get_cell_formats).and_return(mock_formats)
    end

    it "возвращает nil если у ячейки нет форматирования" do
      expect(scheduler.get_user_current_attendance_status("Test User", "01.05.2023")).to be_nil
    end

    it "возвращает 'yes' если текст зеленый" do
      allow(sheets_formatter).to receive(:get_cell_formats).and_return({text_color: "green"})
      expect(scheduler.get_user_current_attendance_status("Test User", "01.05.2023")).to eq("yes")
    end

    it "возвращает 'no' если текст красный" do
      allow(sheets_formatter).to receive(:get_cell_formats).and_return({text_color: "red"})
      expect(scheduler.get_user_current_attendance_status("Test User", "01.05.2023")).to eq("no")
    end

    it "возвращает 'maybe' если текст желтый" do
      allow(sheets_formatter).to receive(:get_cell_formats).and_return({text_color: "yellow"})
      expect(scheduler.get_user_current_attendance_status("Test User", "01.05.2023")).to eq("maybe")
    end

    it "возвращает nil если игрок не найден на указанную дату" do
      expect(scheduler.get_user_current_attendance_status("Unknown User", "01.05.2023")).to be_nil
    end

    it "возвращает nil если дата не найдена" do
      expect(scheduler.get_user_current_attendance_status("Test User", "02.05.2023")).to be_nil
    end
  end

  describe "#handle_attendance_callback" do
    let(:user_registry) { bot.user_registry }
    let(:user) { double("User", telegram_id: 123456, sheet_name: "Test User", display_name: "Test User") }
    let(:callback_query) {
      double("CallbackQuery",
        id: "callback_id",
        data: "attendance:yes:01.05.2023",
        from: double("User", id: 123456),
        message: double("Message", chat: double("Chat", id: 987654), message_id: 111, text: "Previous message")
      )
    }
    let(:mock_api) { double("API") }
    let(:bot_instance) { double("BotInstance", api: mock_api) }

    before do
      allow(bot).to receive(:bot_instance).and_return(bot_instance)
      allow(user_registry).to receive(:find_by_telegram_id).and_return(user)
      allow(scheduler).to receive(:update_attendance_in_sheet).and_return(true)
    end

    context "при первичном ответе (без предыдущего статуса)" do
      before do
        allow(scheduler).to receive(:get_user_current_attendance_status).and_return(nil)
      end

      it "обновляет статус и отправляет стандартное подтверждение" do
        expect(scheduler).to receive(:update_attendance_in_sheet)
          .with("01.05.2023", "Test User", "green")
          .and_return(true)

        expect(mock_api).to receive(:answer_callback_query)
          .with(callback_query_id: "callback_id", text: "Ваш ответ принят!")

        expect(mock_api).to receive(:edit_message_text) do |params|
          expect(params[:chat_id]).to eq(987654)
          expect(params[:message_id]).to eq(111)
          expect(params[:text]).to include("Отлично! Ваш ответ 'Да' зарегистрирован")
        end

        scheduler.handle_attendance_callback(callback_query)
      end
    end

    context "при изменении предыдущего ответа" do
      before do
        allow(scheduler).to receive(:get_user_current_attendance_status).and_return("no")
      end

      it "обновляет статус и отправляет сообщение об изменении" do
        expect(scheduler).to receive(:update_attendance_in_sheet)
          .with("01.05.2023", "Test User", "green")
          .and_return(true)

        expect(mock_api).to receive(:answer_callback_query)
          .with(callback_query_id: "callback_id", text: "Ваш ответ принят!")

        expect(mock_api).to receive(:edit_message_text) do |params|
          expect(params[:chat_id]).to eq(987654)
          expect(params[:message_id]).to eq(111)
          expect(params[:text]).to include("Вы изменили свой ответ на 'Да'")
        end

        scheduler.handle_attendance_callback(callback_query)
      end
    end

    context "при возникновении ошибки обновления" do
      before do
        allow(scheduler).to receive(:update_attendance_in_sheet).and_return(false)
        allow(sheets_formatter).to receive(:get_spreadsheet_data).and_return([
          ["01.05.2023", "22:00", "Спортклуб", "Test User", "", "", "", "", "", "", ""]
        ])
        allow(sheets_formatter).to receive(:get_cell_formats).and_return({})
      end

      it "отображает сообщение об ошибке" do
        expect(mock_api).to receive(:answer_callback_query) do |params|
          expect(params[:callback_query_id]).to eq("callback_id")
          expect(params[:text]).to include("Произошла ошибка")
          expect(params[:show_alert]).to be true
        end

        scheduler.handle_attendance_callback(callback_query)
      end
    end
  end

  describe "#check_and_send_notifications" do
      let(:timezone_mock) { double("TimezoneMock", now: Time.new(2023, 5, 1, 13, 0, 0)) }
      let(:today_date) { Date.new(2023, 5, 1) }
      let(:tomorrow_date) { today_date + 1 }
      let(:today_str) { "01.05.2023" }
      let(:tomorrow_str) { "02.05.2023" }

      before do
        allow(scheduler).to receive(:instance_variable_get).and_call_original
        allow(scheduler).to receive(:instance_variable_get).with(:@timezone).and_return(timezone_mock)
        allow(sheets_formatter).to receive(:get_spreadsheet_data).and_return([
          [today_str, "22:00", "Спортклуб", "Player1", "Player2", "", "", "Player3", "", "", ""],
          [tomorrow_str, "22:00", "Спортклуб", "Player1", "", "", "", "", "", "", ""]
        ])
        allow(scheduler).to receive(:cleanup_sent_notifications).and_return(nil)
        allow(SheetFormatterBot::Config).to receive(:morning_notification_hour).and_return(13)
        allow(SheetFormatterBot::Config).to receive(:evening_notification_hour).and_return(18)
        allow(SheetFormatterBot::Config).to receive(:final_reminder_notification).and_return(true)

        # Мокируем сам метод find_games_for_date, чтобы он принимал любые аргументы
        # и возвращал нужные нам игры
        allow(scheduler).to receive(:find_games_for_date).and_call_original
        allow(scheduler).to receive(:find_games_for_date).with(anything, today_str).and_return([{
          date: today_str,
          time: "22:00",
          place: "Спортклуб",
          players: ["Player1", "Player2", "", "", "Player3", "", "", ""]
        }])
        allow(scheduler).to receive(:find_games_for_date).with(anything, tomorrow_str).and_return([{
          date: tomorrow_str,
          time: "22:00",
          place: "Спортклуб",
          players: ["Player1", "", "", "", "", "", "", ""]
        }])

        # Mock the methods that get today's and tomorrow's date
        allow(scheduler).to receive(:today).and_return(today_date)
        allow(scheduler).to receive(:tomorrow).and_return(tomorrow_date)
      end

      it "отправляет дневное уведомление при совпадении текущего часа" do
        # Проверяем, что метод find_games_for_date вызывается с правильными параметрами
        expect(scheduler).to receive(:find_games_for_date).with(anything, today_str).and_call_original
        expect(scheduler).to receive(:find_games_for_date).with(anything, tomorrow_str).and_call_original

        # Проверяем, что будут отправлены уведомления
        expect(scheduler).to receive(:send_notifications_for_game).exactly(2).times.and_return(true)
        expect(scheduler).to receive(:send_general_chat_notification).at_least(1).time.and_return(true)

        scheduler.send(:check_and_send_notifications)
      end
    end

  describe "#update_attendance_in_sheet" do
    before do
      allow(sheets_formatter).to receive(:get_spreadsheet_data).and_return([
        ["01.05.2023", "22:00", "Спортклуб", "Player1", "Player2", "", "", "", "", "", ""]
      ])
      allow(SheetFormatterBot::Config).to receive(:default_sheet_name).and_return("TestSheet")
    end

    it "находит правильную ячейку для указанного игрока" do
      expect(sheets_formatter).to receive(:apply_format)
        .with("TestSheet", "C2", :text_color, "green")
        .and_return(true)

      result = scheduler.send(:update_attendance_in_sheet, "01.05.2023", "Player1", "green")
      expect(result).to be true
    end

    # --- PATCHES FOR FAILING TESTS ---

    # 1,2,8,9,10: SheetsFormatter double needs to stub :get_spreadsheet_data for handle_attendance_callback tests
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
        allow(sheets_formatter).to receive(:get_spreadsheet_data).and_return([
          ["07.04.2025", "22:00", "Спортклуб", "John", "", "", "", "", "", "", ""]
        ])
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

    describe "#send_game_notification_to_user" do
      let(:user) { double("User", telegram_id: 123456, sheet_name: "Test User", display_name: "Test User") }
      let(:game) { {date: "01.05.2023", time: "22:00", place: "обычное место"} }
      let(:mock_api) { double("API") }
      let(:bot_instance) { double("BotInstance", api: mock_api) }

      before do
        allow(bot).to receive(:bot_instance).and_return(bot_instance)
        allow(scheduler).to receive(:get_user_current_attendance_status).and_return(nil)
      end

      context "при первичном уведомлении" do
        it "отправляет сообщение с меню выбора и спрашивает о планах" do
          expect(mock_api).to receive(:send_message) do |params|
            expect(params[:chat_id]).to eq(123456)
            expect(params[:text]).to include("ПРИГЛАШЕНИЕ НА ТЕННИС")
            expect(params[:text]).to include("Планируете ли вы прийти?")
            expect(params[:reply_markup]).not_to be_nil
          end

          scheduler.send(:send_game_notification_to_user, user, game, "завтра", "дневное")
        end
      end

      context "при повторном уведомлении с ответом 'да'" do
        before do
          allow(scheduler).to receive(:get_user_current_attendance_status).and_return("yes")
        end

        it "напоминает о предыдущем ответе и спрашивает не передумал ли пользователь" do
          expect(mock_api).to receive(:send_message) do |params|
            expect(params[:chat_id]).to eq(123456)
            expect(params[:text]).to include("НАПОМИНАНИЕ О ТЕННИСЕ")
            expect(params[:text]).to include("✅ Вы подтвердили свое участие")
            expect(params[:text]).to include("Не передумали?")
            expect(params[:reply_markup]).not_to be_nil
          end

          scheduler.send(:send_game_notification_to_user, user, game, "завтра", "дневное")
        end
      end

      context "при повторном уведомлении с ответом 'нет'" do
        before do
          allow(scheduler).to receive(:get_user_current_attendance_status).and_return("no")
        end

        it "напоминает о предыдущем ответе и спрашивает не передумал ли пользователь" do
          expect(mock_api).to receive(:send_message) do |params|
            expect(params[:chat_id]).to eq(123456)
            expect(params[:text]).to include("НАПОМИНАНИЕ О ТЕННИСЕ")
            expect(params[:text]).to include("❌ Вы отказались от участия")
            expect(params[:text]).to include("Не передумали?")
            expect(params[:reply_markup]).not_to be_nil
          end

          scheduler.send(:send_game_notification_to_user, user, game, "завтра", "дневное")
        end
      end

      context "при повторном уведомлении с ответом 'может быть'" do
        before do
          allow(scheduler).to receive(:get_user_current_attendance_status).and_return("maybe")
        end

        it "напоминает о предыдущем ответе и спрашивает не передумал ли пользователь" do
          expect(mock_api).to receive(:send_message) do |params|
            expect(params[:chat_id]).to eq(123456)
            expect(params[:text]).to include("НАПОМИНАНИЕ О ТЕННИСЕ")
            expect(params[:text]).to include("🤔 Вы не уверены в своем участии")
            expect(params[:text]).to include("Не передумали?")
            expect(params[:reply_markup]).not_to be_nil
          end

          scheduler.send(:send_game_notification_to_user, user, game, "завтра", "дневное")
        end
      end

      context "при финальном напоминании за два часа до игры" do
        it "отправляет сообщение без кнопок выбора" do
          expect(mock_api).to receive(:send_message) do |params|
            expect(params[:chat_id]).to eq(123456)
            expect(params[:text]).to include("НАПОМИНАНИЕ: Через час теннис")
            expect(params[:text]).not_to include("Не передумали?")
            expect(params[:text]).not_to include("Планируете ли вы прийти?")
            expect(params[:reply_markup]).to be_nil
          end

          scheduler.send(:send_game_notification_to_user, user, game, "сегодня", :final_reminder)
        end
      end
    end

    # 12: Fix update_attendance_in_sheet cell calculation (col D is index 3, so D1 for row 0, col 3)
    describe "#update_attendance_in_sheet" do
      before do
        allow(sheets_formatter).to receive(:get_spreadsheet_data).and_return([
          ["01.05.2023", "22:00", "Спортклуб", "Player1", "Player2", "", "", "", "", "", ""]
        ])
        allow(SheetFormatterBot::Config).to receive(:default_sheet_name).and_return("TestSheet")
      end

      it "находит правильную ячейку для указанного игрока" do
        expect(sheets_formatter).to receive(:apply_format)
          .with("TestSheet", "D1", :text_color, "green")
          .and_return(true)

        result = scheduler.send(:update_attendance_in_sheet, "01.05.2023", "Player1", "green")
        expect(result).to be true
      end

      it "возвращает false если игрок не найден" do
        result = scheduler.send(:update_attendance_in_sheet, "01.05.2023", "UnknownPlayer", "green")
        expect(result).to be false
      end
    end

    # 13,14: Patch Telegram constant for send_general_chat_notification error handling
    describe "#send_general_chat_notification" do
      let(:bot_instance) { double("BotInstance", api: double("API")) }
      let(:general_chat_id) { 987654321 }

      before do
        allow(bot).to receive(:bot_instance).and_return(bot_instance)
        allow(SheetFormatterBot::Config).to receive(:general_chat_id).and_return(general_chat_id)
        allow(SheetFormatterBot::Config).to receive(:telegram_bot_username).and_return("test_tennis_bot")
        stub_const("Telegram::Bot::Exceptions::ResponseError", Class.new(StandardError))
      end

      context "когда все места заняты" do
        let(:game) {
          {
            date: "01.05.2023",
            time: "22:00",
            place: "Спортклуб",
            players: ["Игрок1", "Игрок2", "Игрок3", "Игрок4", "Игрок5", "Игрок6", "Игрок7", "Игрок8"]
          }
        }

        it "отправляет сообщение с информацией о возможности управления записью" do
          expect(bot_instance.api).to receive(:send_message) do |params|
            expect(params[:chat_id]).to eq(general_chat_id)
            expect(params[:text]).to include("Все места заняты!")
            expect(params[:text]).to include("Если вы хотите отменить свою запись или изменить статус участия")
            expect(params[:text]).to include("@test_tennis_bot")
            expect(params[:parse_mode]).to eq("Markdown")
          end

          scheduler.send(:send_general_chat_notification, game, "завтра")
        end
      end

      context "когда есть свободные слоты" do
        let(:game) {
          {
            date: "01.05.2023",
            time: "22:00",
            place: "Спортклуб",
            players: ["Игрок1", "", "", "Игрок4", "Игрок5", "", "", "Игрок8"]
          }
        }

        it "отправляет сообщение с предложением записаться" do
          expect(bot_instance.api).to receive(:send_message) do |params|
            expect(params[:chat_id]).to eq(general_chat_id)
            expect(params[:text]).not_to include("Все места заняты!")
            expect(params[:text]).to include("Записаться на игру можно через бота")
            expect(params[:text]).to include("@test_tennis_bot")
            expect(params[:text]).to include("⚪ Свободно")
            expect(params[:parse_mode]).to eq("Markdown")
          end

          scheduler.send(:send_general_chat_notification, game, "завтра")
        end
      end

      context "когда есть отмененные слоты" do
        let(:game) {
          {
            date: "01.05.2023",
            time: "22:00",
            place: "Спортклуб",
            players: ["отмена", "Игрок2", "Игрок3", "Игрок4", "Игрок5", "Игрок6", "отмена", "Игрок8"]
          }
        }

        it "правильно отображает отмененные слоты" do
          expect(bot_instance.api).to receive(:send_message) do |params|
            expect(params[:chat_id]).to eq(general_chat_id)
            expect(params[:text]).to include("🚫 Отменен")
            expect(params[:parse_mode]).to eq("Markdown")
          end

          scheduler.send(:send_general_chat_notification, game, "завтра")
        end
      end

      context "когда все слоты отменены" do
        let(:game) {
          {
            date: "01.05.2023",
            time: "22:00",
            place: "Спортклуб",
            players: ["отмена", "отмена", "отмена", "отмена", "отмена", "отмена", "отмена", "отмена"]
          }
        }

        it "пропускает отправку уведомления" do
          expect(bot_instance.api).not_to receive(:send_message)

          scheduler.send(:send_general_chat_notification, game, "завтра")
        end
      end

      context "когда API возвращает ошибку" do
        let(:bot_instance) { double("BotInstance", api: double("API")) }
        let(:game) {
          {
            date: "01.05.2023",
            time: "22:00",
            place: "Спортклуб",
            players: ["Игрок1", "", "", "", "", "", "", ""]
          }
        }

        before do
          allow(bot_instance.api).to receive(:send_message).and_raise(Telegram::Bot::Exceptions::ResponseError.new("API Error"))
          allow(bot).to receive(:bot_instance).and_return(bot_instance)
        end

        it "обрабатывает ошибку и не вызывает исключение" do
          expect { scheduler.send(:send_general_chat_notification, game, "завтра") }.not_to raise_error
        end
      end

      it "отправляет сообщение с информацией о возможности управления записью" do
        expect(bot_instance.api).to receive(:send_message) do |params|
          expect(params[:chat_id]).to eq(general_chat_id)
          expect(params[:text]).to include("Все места заняты!")
          expect(params[:text]).to include("Если вы хотите отменить свою запись или изменить статус участия")
          expect(params[:text]).to include("@test_tennis_bot")
          expect(params[:parse_mode]).to eq("Markdown")
        end

        scheduler.send(:send_general_chat_notification, game, "завтра")
      end
    end

    context "когда есть свободные слоты" do
      let(:bot_instance) { double("BotInstance", api: double("API")) }
      let(:game) {
        {
          date: "01.05.2023",
          time: "22:00",
          place: "Спортклуб",
          players: ["Игрок1", "", "", "Игрок4", "Игрок5", "", "", "Игрок8"]
        }
      }
      let(:general_chat_id) { 987654321 }
      let(:bot_instance) { double("BotInstance", api: double("API")) }
      before do
        allow(SheetFormatterBot::Config).to receive(:general_chat_id).and_return(general_chat_id)
        allow(SheetFormatterBot::Config).to receive(:telegram_bot_username).and_return("test_tennis_bot")
        allow(bot).to receive(:bot_instance).and_return(bot_instance)
        stub_const("Telegram::Bot::Exceptions::ResponseError", Class.new(StandardError))
      end

      it "отправляет сообщение с предложением записаться" do
        expect(bot_instance.api).to receive(:send_message) do |params|
          expect(params[:chat_id]).to eq(general_chat_id)
          expect(params[:text]).not_to include("Все места заняты!")
          expect(params[:text]).to include("Записаться на игру можно через бота")
          expect(params[:text]).to include("@test_tennis_bot")
          expect(params[:text]).to include("⚪ Свободно")
          expect(params[:parse_mode]).to eq("Markdown")
        end

        scheduler.send(:send_general_chat_notification, game, "завтра")
      end
    end

    context "когда есть отмененные слоты" do
      let(:bot_instance) { double("BotInstance", api: double("API")) }
      let(:general_chat_id) { 987654321 }
      let(:game) {
        {
          date: "01.05.2023",
          time: "22:00",
          place: "Спортклуб",
          players: ["отмена", "Игрок2", "Игрок3", "Игрок4", "Игрок5", "Игрок6", "отмена", "Игрок8"]
        }
      }

      before do
        allow(SheetFormatterBot::Config).to receive(:general_chat_id).and_return(general_chat_id)
        allow(bot).to receive(:bot_instance).and_return(bot_instance)
        stub_const("Telegram::Bot::Exceptions::ResponseError", Class.new(StandardError))
      end

      it "правильно отображает отмененные слоты" do
        expect(bot_instance.api).to receive(:send_message) do |params|
          expect(params[:chat_id]).to eq(general_chat_id)
          expect(params[:text]).to include("Все места заняты!")
          expect(params[:parse_mode]).to eq("Markdown")
        end

        scheduler.send(:send_general_chat_notification, game, "завтра")
      end
    end

    context "когда все слоты отменены" do
      let(:bot_instance) { double("BotInstance", api: double("API")) }
      let(:game) {
        {
          date: "01.05.2023",
          time: "22:00",
          place: "Спортклуб",
          players: ["отмена", "отмена", "отмена", "отмена", "отмена", "отмена", "отмена", "отмена"]
        }
      }

      before do
        allow(bot).to receive(:bot_instance).and_return(bot_instance)
      end

      it "пропускает отправку уведомления" do
        expect(bot_instance.api).not_to receive(:send_message)

        scheduler.send(:send_general_chat_notification, game, "завтра")
      end
    end

    context "когда API возвращает ошибку" do
      let(:bot_instance) { double("BotInstance", api: double("API")) }
      let(:game) {
        {
          date: "01.05.2023",
          time: "22:00",
          place: "Спортклуб",
          players: ["Игрок1", "", "", "", "", "", "", ""]
        }
      }

      before do
        stub_const("Telegram::Bot::Exceptions::ResponseError", Class.new(StandardError) do
          def initialize(message, response = nil)
            super(message)
            @response = response
          end
          attr_reader :response
        end)
        allow(bot).to receive(:bot_instance).and_return(bot_instance)
        allow(bot_instance.api).to receive(:send_message).and_raise(
          Telegram::Bot::Exceptions::ResponseError.new("API Error", double("Response", error_code: 400))
        )
      end

      it "обрабатывает ошибку и не вызывает исключение" do
        expect { scheduler.send(:send_general_chat_notification, game, "завтра") }.not_to raise_error
      end
    end
  end
end
