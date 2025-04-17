# frozen_string_literal: true

RSpec.describe SheetFormatterBot::TelegramBot do
  let(:token) { "test_token" }
  let(:sheets_formatter) { double("SheetsFormatter") }
  let(:user_registry) { double("UserRegistry") }
  let(:notification_scheduler) { double("NotificationScheduler") }
  let(:bot_instance) { double("BotInstance") }
  let(:api_spy) { spy("API") }

  let(:bot) {
    bot = SheetFormatterBot::TelegramBot.new(
      token: token,
      sheets_formatter: sheets_formatter,
      user_registry: user_registry,
      notification_scheduler: notification_scheduler
    )
    allow(bot).to receive(:bot_instance).and_return(bot_instance)
    allow(bot_instance).to receive(:api).and_return(api_spy)

    allow(bot).to receive(:send_message) do |chat_id, text, **options|
      api_spy.send_message(chat_id: chat_id, text: text, parse_mode: "Markdown", **options)
    end

    allow(bot).to receive(:answer_callback_query) do |callback_query_id, text = nil, show_alert = false|
      api_spy.answer_callback_query(callback_query_id: callback_query_id, text: text, show_alert: show_alert)
    end

    bot
  }

  before do
    allow(SheetFormatterBot::Config).to receive(:admin_telegram_ids).and_return([123456])
    allow(SheetFormatterBot::Config).to receive(:default_sheet_name).and_return("TestSheet")

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

  describe "#show_admin_menu" do
    context "когда пользователь является администратором" do
      it "отображает панель администратора" do
        result = bot.send(:show_admin_menu, 123456)

        expect(result).to be true

        expect(api_spy).to have_received(:send_message) do |params|
        expect(params[:chat_id]).to eq(123456)
        expect(params[:text]).to include("Панель администратора")

        keyboard = params[:reply_markup]
        expect(keyboard).to be_a(Telegram::Bot::Types::InlineKeyboardMarkup)
        expect(keyboard.inline_keyboard.size).to eq(4)

        buttons = keyboard.inline_keyboard.flatten.map(&:text)
        expect(buttons).to include("🔄 Синхронизировать")
        expect(buttons).to include("❌ Отменить корт")
        expect(buttons).to include("🔗 Сопоставить имя")
        expect(buttons).to include("« Вернуться в главное меню")
        end
      end
    end

    context "когда пользователь не является администратором" do
      it "отображает сообщение об ошибке" do
        result = bot.send(:show_admin_menu, 789012)

        expect(result).to be_nil
        expect(api_spy).to have_received(:send_message) do |params|
          expect(params[:chat_id]).to eq(789012)
          expect(params[:text]).to include("нет прав администратора")
        end
      end
    end
  end

  describe "#handle_admin_callback" do
    let(:admin_user) { double("User", telegram_id: 123456, display_name: "Admin", sheet_name: "Admin Name") }
    let(:callback_query) do
      double("CallbackQuery",
        id: "callback123",
        data: "admin:sync",
        from: double("User", id: 123456),
        message: double("Message", chat: double("Chat", id: 123456), message_id: 42)
      )
    end

    context "при выполнении синхронизации" do
      before do
        allow(user_registry).to receive(:size).and_return(5, 6)
        allow(user_registry).to receive(:instance_variable_get).with(:@name_mapping).and_return({}, {"John" => 123})
        allow(user_registry).to receive(:synchronize_users_and_mappings)
        allow(user_registry).to receive(:all_users).and_return([admin_user])
        allow(user_registry).to receive(:create_backup)
      end

      it "выполняет синхронизацию и отправляет отчет" do
        bot.send(:handle_admin_callback, callback_query)

        expect(api_spy).to have_received(:answer_callback_query)
        .with(
          callback_query_id: "callback123",
          text: "Выполняю синхронизацию...",
          show_alert: false
        )

        expect(api_spy).to have_received(:send_message) do |params|
          expect(params[:chat_id]).to eq(123456)
          expect(params[:text]).to include("Синхронизация выполнена")
          expect(params[:text]).to include("Пользователей: 5 -> 6")
          expect(params[:text]).to include("Сопоставлений: 0 -> 1")
        end

        expect(user_registry).to have_received(:synchronize_users_and_mappings)
        expect(user_registry).to have_received(:create_backup)
      end
    end

    context "при запросе на отмену корта" do
      before do
        bot.instance_variable_set(:@user_states, {})
      end

      it "запрашивает дату для отмены" do
        allow(callback_query).to receive(:data).and_return("admin:cancel")

        expect(api_spy).to receive(:answer_callback_query)
        .with(
          callback_query_id: "callback123",
          text: nil,
          show_alert: false
        )

        expect(bot_instance.api).to receive(:send_message) do |params|
          expect(params[:chat_id]).to eq(123456)
          expect(params[:text]).to include("Введите дату")
        end

        bot.send(:handle_admin_callback, callback_query)

        user_state = bot.instance_variable_get(:@user_states)[123456]
        expect(user_state).to eq({ state: :awaiting_cancel_date })
      end
    end

    context "при запросе на сопоставление имени" do
      before do
        bot.instance_variable_set(:@user_states, {})
      end

      it "запрашивает имя для сопоставления" do
        allow(callback_query).to receive(:data).and_return("admin:map")

        expect(api_spy).to receive(:answer_callback_query)
          .with(callback_query_id: "callback123", text: nil, show_alert: false)

          expect(api_spy).to receive(:send_message) do |params|
            expect(params[:chat_id]).to eq(123456)
            expect(params[:text]).to include("Введите имя в таблице")
          end

        bot.send(:handle_admin_callback, callback_query)

        user_state = bot.instance_variable_get(:@user_states)[123456]
        expect(user_state).to eq({ state: :awaiting_map_name })
      end
    end

    context "когда пользователь не администратор" do
      it "отображает сообщение об ошибке" do
        non_admin_callback = double("CallbackQuery",
          id: "callback456",
          data: "admin:sync",
          from: double("User", id: 789012),
          message: double("Message", chat: double("Chat", id: 789012))
        )

        expect(api_spy).to receive(:answer_callback_query)
          .with(callback_query_id: "callback456", text: "У вас нет прав администратора.", show_alert: true)

        bot.send(:handle_admin_callback, non_admin_callback)
      end
    end
  end

  describe "#handle_text_message" do
    before do
      bot.instance_variable_set(:@user_states, {})

      # Стабы для сообщения
      @message = double("Message",
        from: double("User", id: 123456),
        chat: double("Chat", id: 123456),
        text: "Test"
      )
    end

    context "при ожидании даты для отмены корта" do
      before do
        bot.instance_variable_get(:@user_states)[123456] = { state: :awaiting_cancel_date }
      end

      it "принимает корректную дату и запрашивает номер корта" do
        allow(@message).to receive(:text).and_return("01.05.2025")

        expect(bot_instance.api).to receive(:send_message) do |params|
          expect(params[:chat_id]).to eq(123456)
          expect(params[:text]).to include("Теперь введите номер корта")
        end

        result = bot.send(:handle_text_message, @message)
        expect(result).to be true

        # Проверяем обновление состояния
        expect(bot.instance_variable_get(:@user_states)[123456]).to eq({
          state: :awaiting_cancel_court,
          date: "01.05.2025"
        })
      end

      it "отклоняет некорректный формат даты" do
        allow(@message).to receive(:text).and_return("некорректная дата")

        expect(bot_instance.api).to receive(:send_message) do |params|
          expect(params[:chat_id]).to eq(123456)
          expect(params[:text]).to include("Некорректный формат даты")
        end

        result = bot.send(:handle_text_message, @message)
        expect(result).to be true

        # Проверяем, что состояние не изменилось
        expect(bot.instance_variable_get(:@user_states)[123456][:state]).to eq(:awaiting_cancel_date)
      end
    end

    context "при ожидании имени для сопоставления" do
      before do
        bot.instance_variable_get(:@user_states)[123456] = { state: :awaiting_map_name }
      end

      it "принимает имя и запрашивает пользователя" do
        allow(@message).to receive(:text).and_return("John Doe")

        expect(bot_instance.api).to receive(:send_message) do |params|
          expect(params[:chat_id]).to eq(123456)
          expect(params[:text]).to include("Теперь введите @username или ID")
        end

        result = bot.send(:handle_text_message, @message)
        expect(result).to be true

        # Проверяем обновление состояния
        expect(bot.instance_variable_get(:@user_states)[123456]).to eq({
          state: :awaiting_map_user,
          sheet_name: "John Doe"
        })
      end
    end
  end

  describe "#show_main_menu" do
    let(:user) { double("User", telegram_id: 123456, sheet_name: "John Doe") }
    let(:non_admin_user) { double("User", telegram_id: 789012, sheet_name: "Regular User") }

    before do
      allow(user_registry).to receive(:find_by_telegram_id).with(123456).and_return(user)
      allow(user_registry).to receive(:find_by_telegram_id).with(789012).and_return(non_admin_user)
    end

    it "показывает стандартное меню для обычного пользователя" do
      expect(api_spy).to receive(:send_message) do |params|
        expect(params[:chat_id]).to eq(789012)
        expect(params[:text]).to include("Главное меню:")

        keyboard = params[:reply_markup]
        buttons = keyboard.inline_keyboard.flatten.map(&:text)

        expect(buttons).not_to include("🔧 Панель администратора")
        expect(buttons.size).to eq(4)
      end

      bot.send(:show_main_menu, 789012)
    end

    it "добавляет кнопку админ-панели для администратора" do
      expect(api_spy).to receive(:send_message) do |params|
        expect(params[:chat_id]).to eq(123456)

        keyboard = params[:reply_markup]
        buttons = keyboard.inline_keyboard.flatten.map(&:text)

        expect(buttons).to include("🔧 Панель администратора")
        expect(buttons.size).to eq(5)
      end

      bot.send(:show_main_menu, 123456)
    end
  end
end
