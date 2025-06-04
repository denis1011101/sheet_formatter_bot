# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/sheet_formatter_bot/utils/slot_utils"

RSpec.describe SheetFormatterBot::Utils::SlotUtils do
  let(:dummy_class) { Class.new { include SheetFormatterBot::Utils::SlotUtils } }
  let(:utils) { dummy_class.new }

  describe ".IGNORED_SLOT_NAMES" do
    it "contains technical values" do
      expect(described_class::IGNORED_SLOT_NAMES).to include("один корт", "два корта", "корты")
    end
  end

  describe "#slot_cancelled?" do
    it "recognizes cancelled slots" do
      expect(utils.slot_cancelled?("отменен")).to be true
      expect(utils.slot_cancelled?("отменён")).to be true
      expect(utils.slot_cancelled?("отмена")).to be true
      expect(utils.slot_cancelled?("что-то отменен")).to be true
      expect(utils.slot_cancelled?("что-то отменён")).to be true
      expect(utils.slot_cancelled?("что-то отмена")).to be true
    end

    it "does not recognize regular values" do
      expect(utils.slot_cancelled?("игрок")).to be false
      expect(utils.slot_cancelled?("свободно")).to be false
    end
  end

  describe "#format_slots_text" do
    it "returns 'All slots are cancelled' if all are cancelled" do
      expect(utils.format_slots_text(["Отменен", "Отменен"])).to eq("Все слоты отменены")
    end

    it "formats a list of slots with numbers and statuses" do
      slots = ["Отменен", "Свободно", "Игрок"]
      expect(utils.format_slots_text(slots)).to eq(
        "1. 🚫 Отменен\n2. ⚪ Свободно\n3. Игрок"
      )
    end
  end
end
