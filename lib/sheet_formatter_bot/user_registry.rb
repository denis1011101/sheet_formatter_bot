require 'json'
require 'fileutils'
require 'time'

module SheetFormatterBot
  class UserRegistry
    DEFAULT_STORAGE_PATH = './data/users.json'
    DEFAULT_MAPPING_PATH = './data/name_mapping.json'
    DEFAULT_BACKUP_DIR = './data/backups'

    attr_reader :storage_path, :mapping_path, :backup_dir

    def initialize(storage_path = DEFAULT_STORAGE_PATH, mapping_path = DEFAULT_MAPPING_PATH, backup_dir = DEFAULT_BACKUP_DIR)
      @storage_path = storage_path
      @mapping_path = mapping_path
      @backup_dir = backup_dir
      @users = {}
      @name_mapping = {} # Сопоставление имен в таблице с telegram_id

      # Создаем директории для данных и резервных копий, если они не существуют
      FileUtils.mkdir_p(File.dirname(storage_path))
      FileUtils.mkdir_p(File.dirname(mapping_path))
      FileUtils.mkdir_p(backup_dir)

      # Сначала пытаемся загрузить данные из последнего бэкапа, если основные файлы недоступны
      load_users_from_backup unless File.exist?(storage_path)
      load_mapping_from_backup unless File.exist?(mapping_path)

      # Затем загружаем данные из основных файлов, если они есть
      load_users
      load_name_mapping
    end

    def register_user(user)
      @users[user.telegram_id.to_s] = user
      save_users
      user
    end

    def map_sheet_name_to_user(sheet_name, telegram_id)
      @name_mapping[sheet_name] = telegram_id.to_s
      user = find_by_telegram_id(telegram_id)
      user.sheet_name = sheet_name if user
      save_name_mapping
      save_users
    end

    def find_by_telegram_id(telegram_id)
      @users[telegram_id.to_s]
    end

    def find_by_sheet_name(sheet_name)
      return nil if sheet_name.nil? || sheet_name.empty?

      # Проверяем сначала прямое сопоставление
      if @name_mapping.key?(sheet_name)
        return find_by_telegram_id(@name_mapping[sheet_name])
      end

      # Если прямого сопоставления нет, ищем среди пользователей по sheet_name
      @users.values.find { |u| u.sheet_name == sheet_name }
    end

    def find_by_telegram_username(username)
      return nil if username.nil? || username.empty?

      username = username.delete('@') if username.start_with?('@')
      @users.values.find { |u| u.username&.downcase == username.downcase }
    end

    def find_by_name(name)
      return nil if name.nil? || name.empty?

      # Сначала проверяем сопоставление имен
      user = find_by_sheet_name(name)
      return user if user

      # Затем ищем по имени в Telegram
      name_downcase = name.downcase
      @users.values.find do |u|
        u.full_name.downcase == name_downcase ||
        u.first_name&.downcase == name_downcase ||
        u.username&.downcase == name_downcase
      end
    end

    def all_users
      @users.values
    end

    def size
      @users.size
    end

    # Метод для создания резервной копии данных
    def create_backup
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')

      # Резервная копия пользователей
      backup_users_path = File.join(backup_dir, "users_#{timestamp}.json")

      if @users.any?
        data = @users.transform_values(&:to_h)
        File.open(backup_users_path, 'w') do |f|
          f.write(JSON.pretty_generate(data))
        end
      end

      # Резервная копия сопоставлений имен
      backup_mapping_path = File.join(backup_dir, "name_mapping_#{timestamp}.json")

      if @name_mapping.any?
        File.open(backup_mapping_path, 'w') do |f|
          f.write(JSON.pretty_generate(@name_mapping))
        end
      end

      # Очистка старых резервных копий (оставляем только последние 10)
      cleanup_old_backups

      log(:info, "Резервная копия создана: #{timestamp}")
    end

    private

    # Очистка старых резервных копий
    def cleanup_old_backups
      users_backups = Dir.glob(File.join(backup_dir, 'users_*.json')).sort
      mapping_backups = Dir.glob(File.join(backup_dir, 'name_mapping_*.json')).sort

      if users_backups.size > 10
        users_backups[0...-10].each { |file| File.delete(file) }
      end

      if mapping_backups.size > 10
        mapping_backups[0...-10].each { |file| File.delete(file) }
      end
    end

    # Загрузка данных пользователей из последнего бэкапа
    def load_users_from_backup
      latest_backup = Dir.glob(File.join(backup_dir, 'users_*.json')).sort.last
      return unless latest_backup

      log(:info, "Загружаем данные пользователей из резервной копии: #{File.basename(latest_backup)}")

      begin
        data = JSON.parse(File.read(latest_backup))
        data.each do |telegram_id, attrs|
          user = User.new(
            telegram_id: attrs['telegram_id'],
            username: attrs['username'],
            first_name: attrs['first_name'],
            last_name: attrs['last_name']
          )
          user.sheet_name = attrs['sheet_name']
          user.tennis_role = attrs['tennis_role']

          # Восстанавливаем временную метку регистрации
          if attrs['registered_at']
            user.instance_variable_set(:@registered_at, Time.parse(attrs['registered_at']))
          end

          @users[telegram_id] = user
        end

        # Сохраняем восстановленные данные в основной файл
        save_users
      rescue JSON::ParserError => e
        log(:error, "Ошибка при разборе файла резервной копии пользователей: #{e.message}")
      end
    end

    # Загрузка сопоставлений из последнего бэкапа
    def load_mapping_from_backup
      latest_backup = Dir.glob(File.join(backup_dir, 'name_mapping_*.json')).sort.last
      return unless latest_backup

      log(:info, "Загружаем сопоставления имен из резервной копии: #{File.basename(latest_backup)}")

      begin
        @name_mapping = JSON.parse(File.read(latest_backup))

        # Сохраняем восстановленные данные в основной файл
        save_name_mapping
      rescue JSON::ParserError => e
        log(:error, "Ошибка при разборе файла резервной копии сопоставлений: #{e.message}")
        @name_mapping = {}
      end
    end

    def load_users
      return unless File.exist?(storage_path)

      begin
        data = JSON.parse(File.read(storage_path))
        data.each do |telegram_id, attrs|
          user = User.new(
            telegram_id: attrs['telegram_id'],
            username: attrs['username'],
            first_name: attrs['first_name'],
            last_name: attrs['last_name']
          )
          user.sheet_name = attrs['sheet_name']
          user.tennis_role = attrs['tennis_role']

          # Восстанавливаем временную метку регистрации
          if attrs['registered_at']
            user.instance_variable_set(:@registered_at, Time.parse(attrs['registered_at']))
          end

          @users[telegram_id] = user
        end
      rescue JSON::ParserError => e
        log(:error, "Ошибка при разборе файла пользователей: #{e.message}")
      end
    end

    def load_name_mapping
      return unless File.exist?(mapping_path)

      begin
        @name_mapping = JSON.parse(File.read(mapping_path))
      rescue JSON::ParserError => e
        log(:error, "Ошибка при разборе файла сопоставления имен: #{e.message}")
        @name_mapping = {}
      end
    end

    def save_users
      data = @users.transform_values(&:to_h)

      File.open(storage_path, 'w') do |f|
        f.write(JSON.pretty_generate(data))
      end
    end

    def save_name_mapping
      File.open(mapping_path, 'w') do |f|
        f.write(JSON.pretty_generate(@name_mapping))
      end
    end

    def log(level, message)
      puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] [#{level.upcase}] [UserRegistry] #{message}"
    end
  end
end
