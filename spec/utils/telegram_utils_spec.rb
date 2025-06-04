# frozen_string_literal: true

require "rspec"
require_relative "../../lib/sheet_formatter_bot/utils/telegram_utils"

RSpec.describe SheetFormatterBot::Utils::TelegramUtils do
  include described_class

  describe "#escape_markdown" do
    it "returns empty string for nil" do
      expect(escape_markdown(nil)).to eq("")
    end

    it "returns empty string for empty string" do
      expect(escape_markdown("")).to eq("")
    end

    it "escapes all markdown special characters" do
      input = "_*[]()~`>#+-=|{}.!Hello"
      expected = "\\_\\*\\[\\]\\(\\)\\~\\`\\>\\#\\+\\-\\=\\|\\{\\}\\.\\!Hello"
      expect(escape_markdown(input)).to eq(expected)
    end

    it "does not escape normal text" do
      expect(escape_markdown("Тестовое сообщение")).to eq("Тестовое сообщение")
    end

    it "escapes only special characters in mixed text" do
      expect(escape_markdown("Привет! Как дела? [test]_")).to eq("Привет\\! Как дела? \\[test\\]\\_")
    end
  end
end
