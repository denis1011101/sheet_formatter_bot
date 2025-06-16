require 'google/apis/sheets_v4'
require 'googleauth'
require 'set'
require_relative 'utils/constants'

module SheetFormatterBot
  class SheetNotFoundError < SheetsApiError; end
  class InvalidRangeError < SheetsApiError; end
  class InvalidFormatError < SheetsApiError; end

  class SheetsFormatter
    COLOR_MAP = SheetFormatterBot::Utils::Constants::COLOR_MAP.transform_values { |v| v ? Google::Apis::SheetsV4::Color.new(**v) : nil }.freeze

    attr_reader :spreadsheet_id, :credentials_path

    def initialize(spreadsheet_id: Config.spreadsheet_id, credentials_path: Config.credentials_path)
      @spreadsheet_id = spreadsheet_id
      @credentials_path = credentials_path
      @service = nil
      @sheet_ids_cache = {}

      @spreadsheet_data_cache = {
        data: nil,
        expires_at: Time.at(0),
        dates_only: nil,
        dates_expires_at: Time.at(0)
      }

      validate_credentials_path
      log(:info, "SheetsFormatter инициализирован для таблицы: #{spreadsheet_id}")
    end

    def get_dates_list(sheet_name = Config.default_sheet_name)
      if @spreadsheet_data_cache[:dates_only].nil? || Time.now > @spreadsheet_data_cache[:dates_expires_at]
        dates_range = "#{sheet_name}!A1:A50"
        response = authenticated_service.get_spreadsheet_values(spreadsheet_id, dates_range)

        dates = []
        if response.values
          response.values.each do |row|
            if row && row[0] && row[0] =~ /\d{2}\.\d{2}\.\d{4}/
              dates << row[0]
            end
          end
        end

        @spreadsheet_data_cache[:dates_only] = dates
        @spreadsheet_data_cache[:dates_expires_at] = Time.now + 1800
      end

      @spreadsheet_data_cache[:dates_only]
    end

    def get_spreadsheet_data(sheet_name = Config.default_sheet_name)
      max_attempts = 3
      attempts = 0

      begin
        if @spreadsheet_data_cache[:data].nil? || Time.now > @spreadsheet_data_cache[:expires_at]
          dates_range = "#{sheet_name}!A1:A100"
          dates_response = authenticated_service.get_spreadsheet_values(spreadsheet_id, dates_range)

          last_row = 1
          if dates_response.values
            dates_response.values.each_with_index do |row, idx|
              if row && row[0] && row[0] =~ /\d{2}\.\d{2}\.\d{4}/
                last_row = idx + 1
              end
            end
          end

          last_row = [last_row + 5, 50].min

          range = "#{sheet_name}!A1:O#{last_row}"
          log(:debug, "Оптимизированное чтение диапазона: #{range}")

          response = authenticated_service.get_spreadsheet_values(spreadsheet_id, range)
          @spreadsheet_data_cache = {
            data: response.values || [],
            expires_at: Time.now + 600
          }
        end

        @spreadsheet_data_cache[:data]
      rescue Google::Apis::ServerError, Google::Apis::TransmissionError => e
        attempts += 1
        log(:warn, "Google ServerError при получении данных (попытка #{attempts}/#{max_attempts}): #{e.message}")
        if attempts < max_attempts
          sleep 2**attempts
          retry
        else
          log(:error, "Не удалось получить данные из Google Sheets после #{max_attempts} попыток: #{e.message}")
          raise
        end
      end
    end

    def get_spreadsheet_data_for_dates(dates_array, sheet_name = Config.default_sheet_name)
      return [] if dates_array.empty?

      max_attempts = 3
      attempts = 0

      begin
        dates_range = "#{sheet_name}!A1:A100"
        dates_response = authenticated_service.get_spreadsheet_values(spreadsheet_id, dates_range)
        date_rows = dates_response.values.map { |row| row[0] }

        target_rows = []
        dates_array.each do |target_date|
          idx = date_rows.bsearch_index { |date| date && date >= target_date }

          if idx && date_rows[idx] == target_date
            target_rows << idx + 1
          end
        end

        if target_rows.any?
          all_data = []
          target_rows.each do |row_num|
            range = "#{sheet_name}!A#{row_num}:O#{row_num}"
            response = authenticated_service.get_spreadsheet_values(spreadsheet_id, range)
            all_data.concat(response.values || [])
          end
          log(:debug, "Бинарный поиск: найдено #{target_rows.size} строк для дат #{dates_array.join(', ')}")
          return all_data
        end

        []
      rescue Google::Apis::ServerError, Google::Apis::TransmissionError => e
        attempts += 1
        log(:warn, "Google ServerError при получении данных для дат (попытка #{attempts}/#{max_attempts}): #{e.message}")
        if attempts < max_attempts
          sleep 2**attempts
          retry
        else
          log(:error, "Не удалось получить данные для дат после #{max_attempts} попыток: #{e.message}")
          return []
        end
      end
    end

    def get_cell_formats(sheet_name, cell_a1)
      return nil if sheet_name.nil? || cell_a1.nil?

      begin
        result = authenticated_service.get_spreadsheet(
          spreadsheet_id,
          fields: 'sheets.data.rowData.values.effectiveFormat',
          ranges: ["#{sheet_name}!#{cell_a1}"]
        )

        return nil if result.sheets.empty? || result.sheets[0].data.empty?

        values = result.sheets[0].data[0].row_data&.first&.values
        return nil unless values && !values.empty?

        format = values.first.effective_format
        return nil unless format

        formats = {}

        if format.text_format && format.text_format.foreground_color
          color = format.text_format.foreground_color

          if color.red.to_f > 0.7 && color.green.to_f < 0.3 && color.blue.to_f < 0.3
            formats[:text_color] = "red"
            log(:debug, "Обнаружен красный текст в #{cell_a1}: #{color.inspect}")
          elsif color.green.to_f > 0.3 && color.red.to_f < 0.3 && color.blue.to_f < 0.3
            formats[:text_color] = "green"
            log(:debug, "Обнаружен зеленый текст в #{cell_a1}: #{color.inspect}")
          elsif color.red.to_f > 0.7 && color.green.to_f > 0.3 && color.blue.to_f < 0.3
            formats[:text_color] = "yellow"
            log(:debug, "Обнаружен желтый текст в #{cell_a1}: #{color.inspect}")
          elsif (color.red.to_f < 0.2 && color.green.to_f < 0.2 && color.blue.to_f < 0.2) ||
                (color.red.nil? && color.green.nil? && color.blue.nil?)
            formats[:text_color] = "black"
            log(:debug, "Обнаружен черный (дефолтный) текст в #{cell_a1}: #{color.inspect}")
          else
            formats[:text_color] = "other"
            log(:debug, "Обнаружен нестандартный цвет текста в #{cell_a1}: r=#{color.red&.to_f}, g=#{color.green&.to_f}, b=#{color.blue&.to_f}")
          end
        else
          formats[:text_color] = "black"
          log(:debug, "Цвет текста не задан в #{cell_a1}, используется дефолтный (черный)")
        end

        return formats
      rescue Google::Apis::ClientError => e
        log(:error, "Ошибка при получении форматирования ячейки #{cell_a1}: #{e.message}")
        return nil
      end
    end

    def authenticated_service
      @service ||= begin
        log(:debug, "Инициализация Google Sheets Service...")
        s = Google::Apis::SheetsV4::SheetsService.new
        s.authorization = authorize_google_sheets

        s.client_options.application_name = "SheetFormatterBot"

        s.client_options.open_timeout_sec = 60
        s.client_options.read_timeout_sec = 60
        s.client_options.send_timeout_sec = 60

        log(:debug, "Google Sheets Service инициализирован.")
        s
      rescue StandardError => e
        log(:error, "Ошибка инициализации Google Sheets Service: #{e.message}")
        raise Error, "Не удалось инициализировать Google Sheets Service: #{e.message}"
      end
    end

    def clear_cache
      if @spreadsheet_data_cache
        @spreadsheet_data_cache[:data] = nil
        @spreadsheet_data_cache[:dates_only] = nil
        @spreadsheet_data_cache[:expires_at] = Time.at(0)
        @spreadsheet_data_cache[:dates_expires_at] = Time.at(0)
      end
    end

    def update_cell_value(sheet_name, range_a1, value)
      begin
        log(:info, "Обновление значения ячейки #{sheet_name}!#{range_a1} на '#{value}'")

        value_range = Google::Apis::SheetsV4::ValueRange.new(
          range: "#{sheet_name}!#{range_a1}",
          values: [[value]]
        )

        update_request = authenticated_service.update_spreadsheet_value(
          spreadsheet_id,
          "#{sheet_name}!#{range_a1}",
          value_range,
          value_input_option: "USER_ENTERED"
        )

        @spreadsheet_data_cache[:data] = nil

        log(:info, "Значение ячейки обновлено: #{sheet_name}!#{range_a1} -> '#{value}'")
        return true
      rescue Google::Apis::Error => e
        log(:error, "Google API Error при обновлении ячейки: #{e.message} (Status: #{e.status_code}, Body: #{e.body})")
        return false
      rescue StandardError => e
        log(:error, "Ошибка при обновлении ячейки: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        return false
      end
    end

    def apply_format(sheet_name, range_a1, format_type, value = nil)
      sheet_id = get_sheet_id(sheet_name)
      grid_range = parse_a1_range(range_a1, sheet_id)
      request = build_format_request(grid_range, format_type.to_sym, value)

      batch_update_request = Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: [request])

      authenticated_service.batch_update_spreadsheet(spreadsheet_id, batch_update_request)
      log(:info, "Форматирование применено: #{sheet_name}!#{range_a1} -> #{format_type} #{value}")

      @spreadsheet_data_cache[:data] = nil

      true
    rescue Google::Apis::Error => e
      log(:error, "Google API Error: #{e.message} (Status: #{e.status_code}, Body: #{e.body})")
      raise SheetsApiError, "Ошибка Google API: #{e.message}"
    rescue Error => e
      log(:error, "SheetsFormatter Error: #{e.class} - #{e.message}")
      raise e
    rescue StandardError => e
      log(:error, "Неожиданная ошибка SheetsFormatter: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      raise Error, "Неожиданная ошибка при работе с таблицей: #{e.message}"
    end

    private

    def validate_credentials_path
      unless File.exist?(credentials_path)
        raise ConfigError, "Файл учетных данных Google не найден по пути: #{credentials_path}"
      end
    end

    def authorize_google_sheets
      log(:debug, "Аутентификация Google Service Account из #{credentials_path}...")
      Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: File.open(credentials_path),
        scope: Config.google_scopes
      )
    end

    def get_sheet_id(sheet_name)
      return @sheet_ids_cache[sheet_name] if @sheet_ids_cache.key?(sheet_name)

      log(:debug, "Получение ID для листа '#{sheet_name}'...")
      spreadsheet = authenticated_service.get_spreadsheet(spreadsheet_id, fields: 'sheets(properties(sheetId,title))')
      sheet = spreadsheet.sheets.find { |s| s.properties.title == sheet_name }

      raise SheetNotFoundError, "Лист '#{sheet_name}' не найден в таблице #{spreadsheet_id}" unless sheet

      log(:debug, "Лист '#{sheet_name}' найден, ID: #{sheet.properties.sheet_id}")
      @sheet_ids_cache[sheet_name] = sheet.properties.sheet_id
      @sheet_ids_cache[sheet_name]
    end

    def parse_a1_range(a1_notation, sheet_id)
      match = a1_notation.match(/^([A-Z]+)(\d+)$/i)
      raise InvalidRangeError, "Неверный формат ячейки: '#{a1_notation}' (ожидается формат типа A1, B12)" unless match

      col_str = match[1].upcase
      row_index = match[2].to_i - 1

      col_index = col_str.chars.reduce(0) { |sum, char| sum * 26 + (char.ord - 'A'.ord + 1) } - 1

      raise InvalidRangeError, "Неверный индекс строки или колонки для '#{a1_notation}'" if row_index < 0 || col_index < 0

      Google::Apis::SheetsV4::GridRange.new(
        sheet_id: sheet_id,
        start_row_index: row_index, end_row_index: row_index + 1,
        start_column_index: col_index, end_column_index: col_index + 1
      )
    end

    def build_format_request(grid_range, format_type, value)
      cell_format = Google::Apis::SheetsV4::CellFormat.new
      fields_to_update = ""

      case format_type
      when :bold
        cell_format.text_format = Google::Apis::SheetsV4::TextFormat.new(bold: true)
        fields_to_update = 'userEnteredFormat.textFormat.bold'
      when :italic
        cell_format.text_format = Google::Apis::SheetsV4::TextFormat.new(italic: true)
        fields_to_update = 'userEnteredFormat.textFormat.italic'
      when :background
        color_key = value.to_s.downcase
        if COLOR_MAP.key?(color_key)
          cell_format.background_color = COLOR_MAP[color_key]
          fields_to_update = 'userEnteredFormat.backgroundColor'
        else
          raise InvalidFormatError, "Неизвестный цвет фона '#{value}'. Доступные: #{COLOR_MAP.keys.join(', ')}."
        end
      when :text_color
        color_key = value.to_s.downcase
        if COLOR_MAP.key?(color_key)
          cell_format.text_format = Google::Apis::SheetsV4::TextFormat.new(
            foreground_color: COLOR_MAP[color_key]
          )
          fields_to_update = 'userEnteredFormat.textFormat.foregroundColor'
        else
          raise InvalidFormatError, "Неизвестный цвет текста '#{value}'. Доступные: #{COLOR_MAP.keys.join(', ')}."
        end
      when :clear
        fields_to_update = 'userEnteredFormat(textFormat.bold,textFormat.italic,backgroundColor,textFormat.foregroundColor)'
      else
        raise InvalidFormatError, "Неизвестный тип форматирования '#{format_type}'. Доступные: bold, italic, background, text_color, clear."
      end

      {
        repeat_cell: Google::Apis::SheetsV4::RepeatCellRequest.new(
          range: grid_range,
          cell: Google::Apis::SheetsV4::CellData.new(user_entered_format: cell_format),
          fields: fields_to_update
        )
      }
    end

    def log(level, message)
      puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] [#{level.upcase}] #{message}"
    end
  end
end
