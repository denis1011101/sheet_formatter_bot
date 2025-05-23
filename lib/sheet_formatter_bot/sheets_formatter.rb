require 'google/apis/sheets_v4'
require 'googleauth'

module SheetFormatterBot
  class SheetNotFoundError < SheetsApiError; end
  class InvalidRangeError < SheetsApiError; end
  class InvalidFormatError < SheetsApiError; end

  class SheetsFormatter
    COLOR_MAP = {
      'red'    => { red: 1.0, green: 0.0, blue: 0.0 },
      'green'  => { red: 0.0, green: 0.5, blue: 0.0 },
      'blue'   => { red: 0.0, green: 0.0, blue: 1.0 },
      'yellow' => { red: 1.0, green: 0.5, blue: 0.0 },
      'white'  => { red: 1.0, green: 1.0, blue: 1.0 },
      'black'  => { red: 0.0, green: 0.0, blue: 0.0 },
      'none'   => nil
    }.transform_values { |v| v ? Google::Apis::SheetsV4::Color.new(**v) : nil }.freeze

    attr_reader :spreadsheet_id, :credentials_path

    def initialize(spreadsheet_id: Config.spreadsheet_id, credentials_path: Config.credentials_path)
      @spreadsheet_id = spreadsheet_id
      @credentials_path = credentials_path
      @service = nil
      @sheet_ids_cache = {}
      @spreadsheet_data_cache = { data: nil, expires_at: Time.now }
      validate_credentials_path
    end

    # Получить все данные таблицы
    def get_spreadsheet_data(sheet_name = Config.default_sheet_name)
      # Используем кэш, если данные не старше 5 минут
      if @spreadsheet_data_cache[:data].nil? || Time.now > @spreadsheet_data_cache[:expires_at]
        range = "#{sheet_name}!A1:Z100" # Берем большой диапазон, который охватывает все данные
        response = authenticated_service.get_spreadsheet_values(spreadsheet_id, range)
        @spreadsheet_data_cache = {
          data: response.values || [],
          expires_at: Time.now + 300 # Кэш на 5 минут
        }
      end

      @spreadsheet_data_cache[:data]
    end

    def get_cell_formats(sheet_name, cell_a1)
      # Обновляем кеш, если необходимо
      return nil if sheet_name.nil? || cell_a1.nil?

      begin
        # Получаем информацию о форматировании ячейки
        result = authenticated_service.get_spreadsheet(
          spreadsheet_id,
          fields: 'sheets.data.rowData.values.effectiveFormat',
          ranges: ["#{sheet_name}!#{cell_a1}"]
        )

        # Анализируем результат
        return nil if result.sheets.empty? || result.sheets[0].data.empty?

        values = result.sheets[0].data[0].row_data&.first&.values
        return nil unless values && !values.empty?

        format = values.first.effective_format
        return nil unless format

        # Возвращаем информацию о форматировании в виде хеша
        formats = {}

        # Получаем цвет текста, если он установлен
        if format.text_format && format.text_format.foreground_color
          color = format.text_format.foreground_color

          # Более надежное определение цветов по диапазону значений
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
            formats[:text_color] = "black" # Дефолтный цвет
            log(:debug, "Обнаружен черный (дефолтный) текст в #{cell_a1}: #{color.inspect}")
          else
            # Для любых других цветов, которые не подходят под наши условия
            formats[:text_color] = "other"
            log(:debug, "Обнаружен нестандартный цвет текста в #{cell_a1}: r=#{color.red&.to_f}, g=#{color.green&.to_f}, b=#{color.blue&.to_f}")
          end
        else
          # Если foreground_color не задан, считаем что это дефолтный (черный) цвет
          formats[:text_color] = "black"
          log(:debug, "Цвет текста не задан в #{cell_a1}, используется дефолтный (черный)")
        end

        return formats
      rescue Google::Apis::ClientError => e
        log(:error, "Ошибка при получении форматирования ячейки #{cell_a1}: #{e.message}")
        return nil
      end
    end

    # Метод для доступа к сервису Google Sheets API
    def authenticated_service
      @service ||= begin
        log(:debug, "Инициализация Google Sheets Service...")
        s = Google::Apis::SheetsV4::SheetsService.new
        s.authorization = authorize_google_sheets
        log(:debug, "Google Sheets Service инициализирован.")
        s
      rescue StandardError => e
        log(:error, "Ошибка инициализации Google Sheets Service: #{e.message}")
        raise Error, "Не удалось инициализировать Google Sheets Service: #{e.message}"
      end
    end

    def spreadsheet_id
      @spreadsheet_id
    end

    def clear_cache
      @spreadsheet_data_cache[:data] = nil if @spreadsheet_data_cache
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
          value_input_option: 'USER_ENTERED'
        )

        # Сбрасываем кэш после изменения
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

      # Сбрасываем кэш после изменения
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
      row_index = match[2].to_i - 1 # 0-based index

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
      when :text_color # Добавляем новый тип форматирования для цвета текста
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
