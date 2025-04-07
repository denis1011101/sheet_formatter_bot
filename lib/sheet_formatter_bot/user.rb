module SheetFormatterBot
  class User
    attr_reader :telegram_id, :username, :first_name, :last_name, :registered_at
    attr_accessor :sheet_name, :tennis_role

    def initialize(telegram_id:, username: nil, first_name: nil, last_name: nil)
      @telegram_id = telegram_id
      @username = username
      @first_name = first_name
      @last_name = last_name
      @sheet_name = nil # Имя в таблице (может отличаться от имени в Telegram)
      @tennis_role = nil # Может быть "player", "trainer", и т.д.
      @registered_at = Time.now
    end

    def full_name
      [@first_name, @last_name].compact.join(' ')
    end

    def display_name
      return username unless username.to_s.empty?
      return full_name unless full_name.empty?

      telegram_id.to_s
    end

    def to_h
      {
        telegram_id: telegram_id,
        username: username,
        first_name: first_name,
        last_name: last_name,
        sheet_name: sheet_name,
        tennis_role: tennis_role,
        registered_at: registered_at
      }
    end

    def self.from_telegram_user(user)
      new(
        telegram_id: user.id,
        username: user.username,
        first_name: user.first_name,
        last_name: user.last_name
      )
    end
  end
end
