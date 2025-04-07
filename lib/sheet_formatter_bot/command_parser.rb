# lib/sheet_formatter_bot/command_parser.rb
module SheetFormatterBot
  module CommandParser
    Command = Struct.new(:pattern, :handler_method, :description)
    COMMANDS = []

    def self.register(pattern, handler_method, description)
      COMMANDS << Command.new(pattern, handler_method, description)
      # log(:debug, "Зарегистрирована команда: #{pattern} -> #{handler_method}") # Раскомментируйте для отладки
    end

    # Метод парсинга, вызываемый из TelegramBot
    # context - это экземпляр TelegramBot
    def self.dispatch(message, context)
      text = message.text&.strip
      return if text.nil? || text.empty?

      COMMANDS.each do |cmd|
        match = text.match(cmd.pattern)
        if match
          log(:info, "Команда '#{text}' соответствует #{cmd.pattern}, вызов #{context.class}##{cmd.handler_method}")
          context.send(cmd.handler_method, message, match.captures)
          return true # Команда найдена и обработана
        end
      end

      log(:info, "Команда '#{text}' не распознана.")
      false # Команда не найдена
    end

    def self.help_text
      COMMANDS.map { |cmd| "`#{cmd.description}`" }.join("\n")
    end

    # --- Регистрация команд ---
    # Используем константу с цветами из SheetsFormatter
    valid_colors = SheetsFormatter::COLOR_MAP.keys.join('|')

    register(
      /^\/start$/i,
      :handle_start,
      "/start - Показать приветствие и список команд"
    )
    register(
      %r{^/format\s+([A-Z]+\d+)\s+(bold|italic|clear)$}i,
      :handle_format_simple,
      "/format <Ячейка> <bold|italic|clear> - Стиль текста (Пример: /format A1 bold)"
    )
    register(
      %r{^/format\s+([A-Z]+\d+)\s+background\s+(#{valid_colors})$}i,
      :handle_format_background,
      "/format <Ячейка> background <цвет> - Цвет фона (Пример: /format B2 background green)"
    )

    # --- Вспомогательный метод логирования (можно вынести в отдельный модуль) ---
    def self.log(level, message)
        puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] [#{level.upcase}] [CommandParser] #{message}"
    end
  end
end

