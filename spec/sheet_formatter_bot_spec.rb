# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe SheetFormatterBot do
  it "has a version number" do
    expect(SheetFormatterBot::VERSION).not_to be nil
  end
end

RSpec.describe SheetFormatterBot::User do
  describe "initialization" do
    it "creates a new user with required attributes" do
      user = SheetFormatterBot::User.new(telegram_id: 123456)

      expect(user.telegram_id).to eq(123456)
      expect(user.username).to be_nil
      expect(user.first_name).to be_nil
      expect(user.last_name).to be_nil
      expect(user.sheet_name).to be_nil
      expect(user.tennis_role).to be_nil
      expect(user.registered_at).to be_a(Time)
    end

    it "creates a user with all attributes" do
      user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        username: "testuser",
        first_name: "Test",
        last_name: "User"
      )

      expect(user.telegram_id).to eq(123456)
      expect(user.username).to eq("testuser")
      expect(user.first_name).to eq("Test")
      expect(user.last_name).to eq("User")
    end
  end

  describe "#full_name" do
    it "returns the combined first and last name" do
      user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        first_name: "Test",
        last_name: "User"
      )

      expect(user.full_name).to eq("Test User")
    end

    it "returns just the first name when last name is nil" do
      user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        first_name: "Test"
      )

      expect(user.full_name).to eq("Test")
    end
  end

  describe "#display_name" do
    it "returns username if available" do
      user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        username: "testuser",
        first_name: "Test"
      )

      expect(user.display_name).to eq("testuser")
    end

    it "returns full name if username is not available" do
      user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        first_name: "Test",
        last_name: "User"
      )

      expect(user.display_name).to eq("Test User")
    end

    it "returns telegram_id as string if no username or name available" do
      user = SheetFormatterBot::User.new(telegram_id: 123456)

      expect(user.display_name).to eq("123456")
    end
  end

  describe ".from_telegram_user" do
    it "creates a user from a Telegram user object" do
      telegram_user = double(
        id: 123456,
        username: "testuser",
        first_name: "Test",
        last_name: "User"
      )

      user = SheetFormatterBot::User.from_telegram_user(telegram_user)

      expect(user.telegram_id).to eq(123456)
      expect(user.username).to eq("testuser")
      expect(user.first_name).to eq("Test")
      expect(user.last_name).to eq("User")
    end
  end
end

RSpec.describe SheetFormatterBot::CommandParser do
  before do
    # Перезагружаем команды перед каждым тестом
    SheetFormatterBot::CommandParser.define_commands
  end

  describe ".dispatch" do
    let(:context) { double("TelegramBot") }
    let(:message) { double("Message", text: "/start", from: double("User", id: 123)) }

    it "dispatches a valid command to the correct handler" do
      expect(context).to receive(:handle_start).with(message, [])

      result = SheetFormatterBot::CommandParser.dispatch(message, context)
      expect(result).to be true
    end

    it "returns false for unrecognized commands" do
      allow(message).to receive(:text).and_return("/unknowncommand")
      expect(context).not_to receive(:handle_start)

      result = SheetFormatterBot::CommandParser.dispatch(message, context)
      expect(result).to be false
    end

    it "extracts parameters from commands" do
      allow(message).to receive(:text).and_return("/myname John Doe")
      expect(context).to receive(:handle_set_sheet_name).with(message, ["John Doe"])

      SheetFormatterBot::CommandParser.dispatch(message, context)
    end

    it "handles empty messages" do
      allow(message).to receive(:text).and_return("")
      expect(context).not_to receive(:handle_start)

      result = SheetFormatterBot::CommandParser.dispatch(message, context)
      expect(result).to be_nil
    end

    it "handles nil messages" do
      allow(message).to receive(:text).and_return(nil)
      expect(context).not_to receive(:handle_start)

      result = SheetFormatterBot::CommandParser.dispatch(message, context)
      expect(result).to be_nil
    end
  end

  describe ".help_text" do
    it "returns a string with all command descriptions" do
      help_text = SheetFormatterBot::CommandParser.help_text

      expect(help_text).to be_a(String)
      expect(help_text).to include("/start")
      expect(help_text).to include("/map")
      expect(help_text).to include("/myname")
      expect(help_text).to include("/mappings")
      expect(help_text).to include("/test")
    end
  end
end

RSpec.describe SheetFormatterBot::UserRegistry do
  let(:temp_dir) { File.join(Dir.tmpdir, "sheet_formatter_bot_test_#{Time.now.to_i}") }
  let(:storage_path) { File.join(temp_dir, "users.json") }
  let(:mapping_path) { File.join(temp_dir, "name_mapping.json") }
  let(:backup_dir) { File.join(temp_dir, "backups") }

  before do
    FileUtils.mkdir_p(temp_dir)
    FileUtils.mkdir_p(backup_dir)
  end

  after do
    FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
  end

  let(:registry) {
    SheetFormatterBot::UserRegistry.new(storage_path, mapping_path, backup_dir)
  }

  describe "#register_user" do
    it "registers a new user" do
      user = SheetFormatterBot::User.new(telegram_id: 123456)

      registry.register_user(user)

      expect(registry.find_by_telegram_id(123456)).to eq(user)
      expect(File.exist?(storage_path)).to be true
    end

    it "overwrites an existing user with the same ID" do
      user1 = SheetFormatterBot::User.new(
        telegram_id: 123456,
        username: "old_user"
      )
      user2 = SheetFormatterBot::User.new(
        telegram_id: 123456,
        username: "new_user"
      )

      registry.register_user(user1)
      registry.register_user(user2)

      found_user = registry.find_by_telegram_id(123456)
      expect(found_user).to eq(user2)
      expect(found_user.username).to eq("new_user")
    end
  end

  describe "#map_sheet_name_to_user" do
    it "maps a sheet name to a user" do
      user = SheetFormatterBot::User.new(telegram_id: 123456)
      registry.register_user(user)

      registry.map_sheet_name_to_user("John", 123456)

      expect(user.sheet_name).to eq("John")
      expect(registry.find_by_sheet_name("John")).to eq(user)
      expect(File.exist?(mapping_path)).to be true
    end
  end

  describe "#find_by_name" do
    before do
      @user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        username: "testuser",
        first_name: "Test",
        last_name: "User"
      )
      registry.register_user(@user)
      registry.map_sheet_name_to_user("TestSheet", 123456)
    end

    it "finds a user by sheet name" do
      expect(registry.find_by_name("TestSheet")).to eq(@user)
    end

    it "finds a user by first name" do
      expect(registry.find_by_name("Test")).to eq(@user)
    end

    it "finds a user by full name" do
      expect(registry.find_by_name("Test User")).to eq(@user)
    end

    it "finds a user by username" do
      expect(registry.find_by_name("testuser")).to eq(@user)
    end

    it "returns nil for unknown name" do
      expect(registry.find_by_name("Unknown")).to be_nil
    end
  end

  describe "#find_by_telegram_username" do
    before do
      @user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        username: "testuser"
      )
      registry.register_user(@user)
    end

    it "finds a user by username" do
      expect(registry.find_by_telegram_username("testuser")).to eq(@user)
    end

    it "finds a user by username with @ prefix" do
      expect(registry.find_by_telegram_username("@testuser")).to eq(@user)
    end

    it "is case insensitive" do
      expect(registry.find_by_telegram_username("TestUser")).to eq(@user)
    end
  end

  describe "#create_backup" do
    it "creates backup files" do
      user = SheetFormatterBot::User.new(telegram_id: 123456)
      registry.register_user(user)
      registry.map_sheet_name_to_user("TestName", 123456)

      registry.create_backup

      user_backups = Dir.glob(File.join(backup_dir, 'users_*.json'))
      mapping_backups = Dir.glob(File.join(backup_dir, 'name_mapping_*.json'))

      expect(user_backups).not_to be_empty
      expect(mapping_backups).not_to be_empty
    end
  end

  describe "file persistence" do
    it "reloads user data from files" do
      user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        username: "testuser",
        first_name: "Test",
        last_name: "User"
      )
      registry.register_user(user)
      registry.map_sheet_name_to_user("TestName", 123456)

      # Create a new registry to test loading from files
      new_registry = SheetFormatterBot::UserRegistry.new(storage_path, mapping_path, backup_dir)

      loaded_user = new_registry.find_by_telegram_id(123456)
      expect(loaded_user).not_to be_nil
      expect(loaded_user.telegram_id).to eq(123456)
      expect(loaded_user.username).to eq("testuser")
      expect(loaded_user.sheet_name).to eq("TestName")
    end
  end
end

RSpec.describe SheetFormatterBot::Config do
  describe ".telegram_token" do
    it "returns the value from environment variable" do
      allow(ENV).to receive(:fetch).with('TELEGRAM_BOT_TOKEN').and_return('test_token')
      expect(SheetFormatterBot::Config.telegram_token).to eq('test_token')
    end

    it "raises ConfigError if environment variable is not set" do
      allow(ENV).to receive(:fetch).with('TELEGRAM_BOT_TOKEN').and_raise(KeyError)
      expect {
        SheetFormatterBot::Config.telegram_token
      }.to raise_error(KeyError)
    end
  end

  describe ".default_sheet_name" do
    it "returns the value from environment variable if set" do
      allow(ENV).to receive(:fetch).with('DEFAULT_SHEET_NAME', 'Лист1').and_return('Custom Sheet')
      expect(SheetFormatterBot::Config.default_sheet_name).to eq('Custom Sheet')
    end

    it "returns the default value if environment variable is not set" do
      allow(ENV).to receive(:fetch).with('DEFAULT_SHEET_NAME', 'Лист1').and_return('Лист1')
      expect(SheetFormatterBot::Config.default_sheet_name).to eq('Лист1')
    end
  end
end

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
        .with(callback_query_id: "123", text: "Произошла ошибка при обновлении данных.")

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
end

RSpec.describe SheetFormatterBot::SheetsFormatter do
  # Используем моки для Google API
  let(:sheets_service) { double("SheetsService", authorization: nil) }
  let(:spreadsheet_id) { "test_spreadsheet_id" }
  let(:credentials_path) { "./credentials.json" }
  let(:formatter) {
    allow(File).to receive(:exist?).and_return(true)
    allow(Google::Apis::SheetsV4::SheetsService).to receive(:new).and_return(sheets_service)
    allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_return(nil)

    allow_any_instance_of(SheetFormatterBot::SheetsFormatter).to receive(:authorize_google_sheets).and_return(double("GoogleAuthCredentials"))
    allow(sheets_service).to receive(:authorization=)

    SheetFormatterBot::SheetsFormatter.new(
      spreadsheet_id: spreadsheet_id,
      credentials_path: credentials_path
    )
  }

  before do
    allow(SheetFormatterBot::Config).to receive(:spreadsheet_id).and_return(spreadsheet_id)
    allow(SheetFormatterBot::Config).to receive(:credentials_path).and_return(credentials_path)
    allow(SheetFormatterBot::Config).to receive(:google_scopes).and_return(["https://www.googleapis.com/auth/spreadsheets"])

    allow(formatter).to receive(:get_sheet_id).and_return(123)
  end

  describe "#get_spreadsheet_data" do
    it "returns data from the spreadsheet" do
      sheet_name = "TestSheet"
      mock_response = double("Response", values: [["A1", "B1"], ["A2", "B2"]])

      expect(sheets_service).to receive(:get_spreadsheet_values)
        .with(spreadsheet_id, "#{sheet_name}!A1:Z100")
        .and_return(mock_response)

      result = formatter.get_spreadsheet_data(sheet_name)
      expect(result).to eq([["A1", "B1"], ["A2", "B2"]])
    end

    it "returns an empty array if no values are found" do
      sheet_name = "EmptySheet"
      mock_response = double("Response", values: nil)

      expect(sheets_service).to receive(:get_spreadsheet_values)
        .with(spreadsheet_id, "#{sheet_name}!A1:Z100")
        .and_return(mock_response)

      result = formatter.get_spreadsheet_data(sheet_name)
      expect(result).to eq([])
    end

    it "uses caching to avoid repeated API calls" do
      sheet_name = "TestSheet"
      mock_response = double("Response", values: [["A1", "B1"], ["A2", "B2"]])

      expect(sheets_service).to receive(:get_spreadsheet_values).once
        .with(spreadsheet_id, "#{sheet_name}!A1:Z100")
        .and_return(mock_response)

      # Первый вызов должен сделать запрос к API
      formatter.get_spreadsheet_data(sheet_name)

      # Второй вызов должен использовать кэш
      result = formatter.get_spreadsheet_data(sheet_name)
      expect(result).to eq([["A1", "B1"], ["A2", "B2"]])
    end
  end

  describe "#apply_format" do
    before do
      # Create a more complete mock of BatchUpdateSpreadsheetRequest
      stub_const("Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest", Class.new do
        attr_accessor :requests
        def initialize(requests: [])
          @requests = requests
        end
      end)

      # Other Google API classes we need to mock
      stub_const("Google::Apis::SheetsV4::GridRange", Class.new do
        attr_accessor :sheet_id, :start_row_index, :end_row_index, :start_column_index, :end_column_index
        def initialize(sheet_id:, start_row_index:, end_row_index:, start_column_index:, end_column_index:)
          @sheet_id = sheet_id
          @start_row_index = start_row_index
          @end_row_index = end_row_index
          @start_column_index = start_column_index
          @end_column_index = end_column_index
        end
      end)

      stub_const("Google::Apis::SheetsV4::RepeatCellRequest", Class.new do
        attr_accessor :range, :cell, :fields
        def initialize(range: nil, cell: nil, fields: nil)
          @range = range
          @cell = cell
          @fields = fields
        end
      end)

      stub_const("Google::Apis::SheetsV4::CellData", Class.new do
        attr_accessor :user_entered_format
        def initialize(user_entered_format: nil)
          @user_entered_format = user_entered_format
        end
      end)

      stub_const("Google::Apis::SheetsV4::CellFormat", Class.new do
        attr_accessor :text_format, :background_color
      end)

      stub_const("Google::Apis::SheetsV4::TextFormat", Class.new do
        attr_accessor :bold, :italic, :foreground_color
        def initialize(bold: nil, italic: nil, foreground_color: nil)
          @bold = bold
          @italic = italic
          @foreground_color = foreground_color
        end
      end)

      stub_const("Google::Apis::SheetsV4::Color", Class.new do
        attr_accessor :red, :green, :blue
        def initialize(red: nil, green: nil, blue: nil)
          @red = red
          @green = green
          @blue = blue
        end
      end)
    end

    it "sends correct format request for text color" do
      batch_update_request = nil

      # Мокируем get_sheet_id для получения ID листа
      allow(formatter).to receive(:get_sheet_id).with("TestSheet").and_return(123)

      # Перехватываем запрос на обновление
      expect(sheets_service).to receive(:batch_update_spreadsheet) do |id, request|
        batch_update_request = request
        double("UpdateResponse")
      end

      formatter.apply_format("TestSheet", "B2", :text_color, "green")

      # Проверяем, что запрос содержит правильные параметры
      expect(batch_update_request).to be_a(Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest)
      expect(batch_update_request.requests.size).to eq(1)

      repeat_cell = batch_update_request.requests.first[:repeat_cell]
      expect(repeat_cell).not_to be_nil
      expect(repeat_cell.fields).to eq('userEnteredFormat.textFormat.foregroundColor')
    end

    it "raises an error for invalid format type" do
      # Просто убедимся, что правильное исключение выбрасывается
      # Замокаем метод parse_a1_range, чтобы избежать проблем с инициализацией GridRange
      allow(formatter).to receive(:parse_a1_range).and_return(
        double("GridRange")
      )

      expect {
        formatter.apply_format("TestSheet", "B2", :invalid_format, "value")
      }.to raise_error(SheetFormatterBot::InvalidFormatError)
    end

    it "raises an error for invalid color" do
      # Аналогично, замокаем parse_a1_range для этого теста
      allow(formatter).to receive(:parse_a1_range).and_return(
        double("GridRange")
      )

      expect {
        formatter.apply_format("TestSheet", "B2", :text_color, "invalid_color")
      }.to raise_error(SheetFormatterBot::InvalidFormatError)
    end
  end
end
