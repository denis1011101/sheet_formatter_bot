# lib/sheet_formatter_bot/command_parser.rb
module SheetFormatterBot
  module CommandParser
    Command = Struct.new(:pattern, :handler_method, :description)
    COMMANDS = []

    def self.register(pattern, handler_method, description)
      COMMANDS << Command.new(pattern, handler_method, description)
    end

    # Метод парсинга, вызываемый из TelegramBot
    # context - это экземпляр TelegramBot
    def self.dispatch(message, context)
      text = message.text&.strip
      return if text.nil? || text.empty?

      COMMANDS.each do |cmd|
        match = text.match(cmd.pattern)
        next unless match

        log(:info, "Команда '#{text}' соответствует #{cmd.pattern}, вызов #{context.class}##{cmd.handler_method}")
        context.send(cmd.handler_method, message, match.captures)
        return true # Команда найдена и обработана
      end

      log(:info, "Команда '#{text}' не распознана.")
      false # Команда не найдена
    end

    def self.help_text
      COMMANDS.map { |cmd| "`#{cmd.description}`" }.join("\n")
    end

    # Используем метапрограммирование для динамической регистрации команд
    def self.define_commands
      # Очистим текущие команды перед регистрацией новых
      COMMANDS.clear

      # --- Основные команды ---
      register(
        %r{^/start$}i,
        :handle_start,
        "/start - Регистрация в боте и показ справки"
      )

      # --- Команды для управления сопоставлением имен ---
      register(
        %r{^/map\s+(\S+)\s+(@\S+|\S+@\S+|\d+)$}i,
        :handle_name_mapping,
        "/map <Имя_в_таблице> <@username или ID> - Сопоставить имя в таблице с пользователем Telegram"
      )

      register(
        %r{^/myname\s+(.+)$}i,
        :handle_set_sheet_name,
        "/myname <Имя_в_таблице> - Указать свое имя в таблице"
      )

      register(
        %r{^/mappings$}i,
        :handle_show_mappings,
        "/mappings - Показать текущие Список имён имен"
      )

      # Команды для администратора
      register(
        %r{^/sync$}i,
        :handle_sync_registry,
        "/sync - Синхронизировать базу пользователей и сопоставлений (для администратора)"
      )

      register(
        %r{^/cancel\s+(\d{2}\.\d{2}\.\d{4})\s+(\d+)$}i,
        :handle_cancel_court,
        "/cancel <дата> <номер_корта> - Отметить корт как отмененный (только для администратора)"
      )

      # --- Команда для тестирования уведомлений ---
      register(
        %r{^/test$}i,
        :handle_test_notification,
        "/test - Отправить тестовое уведомление"
      )
    end

    # Инициализируем команды сразу при загрузке модуля
    define_commands

    # --- Вспомогательный метод логирования ---
    def self.log(level, message)
      puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] [#{level.upcase}] [CommandParser] #{message}"
    end
  end
end
