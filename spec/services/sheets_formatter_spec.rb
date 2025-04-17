# frozen_string_literal: true

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
