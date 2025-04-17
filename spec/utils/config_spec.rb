# frozen_string_literal: true

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

  describe ".timezone" do
    it "возвращает значение из переменной окружения" do
      allow(ENV).to receive(:fetch).with('TIMEZONE', 'Asia/Yekaterinburg').and_return('Europe/Moscow')
      expect(SheetFormatterBot::Config.timezone).to eq('Europe/Moscow')
    end

    it "возвращает значение по умолчанию если переменная не установлена" do
      allow(ENV).to receive(:fetch).with('TIMEZONE', 'Asia/Yekaterinburg').and_return('Asia/Yekaterinburg')
      expect(SheetFormatterBot::Config.timezone).to eq('Asia/Yekaterinburg')
    end
  end

  describe ".admin_telegram_ids" do
    it "возвращает массив ID из переменной окружения" do
      allow(ENV).to receive(:fetch).with('ADMIN_TELEGRAM_IDS', '').and_return('123456,789012')
      expect(SheetFormatterBot::Config.admin_telegram_ids).to eq([123456, 789012])
    end

    it "возвращает пустой массив если переменная не установлена" do
      allow(ENV).to receive(:fetch).with('ADMIN_TELEGRAM_IDS', '').and_return('')
      expect(SheetFormatterBot::Config.admin_telegram_ids).to eq([])
    end
  end
end
