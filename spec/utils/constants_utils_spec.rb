# frozen_string_literal: true

require "rspec"
require_relative "../../lib/sheet_formatter_bot/utils/constants"

RSpec.describe SheetFormatterBot::Utils::Constants do
  describe "IGNORED_SLOT_NAMES" do
    it "contains expected values" do
      expect(described_class::IGNORED_SLOT_NAMES).to include("отмена", "отменен", "отменить", "cancel", "хард")
      expect(described_class::IGNORED_SLOT_NAMES).to be_an(Array)
    end
  end

  describe "STATUS_YES/NO/MAYBE" do
    it "has correct values" do
      expect(described_class::STATUS_YES).to eq("yes")
      expect(described_class::STATUS_NO).to eq("no")
      expect(described_class::STATUS_MAYBE).to eq("maybe")
    end
  end

  describe "STATUS_COLORS" do
    it "maps statuses to colors" do
      expect(described_class::STATUS_COLORS[described_class::STATUS_YES]).to eq("green")
      expect(described_class::STATUS_COLORS[described_class::STATUS_NO]).to eq("red")
      expect(described_class::STATUS_COLORS[described_class::STATUS_MAYBE]).to eq("yellow")
    end
  end

  describe "error when accessing a non-existent constant" do
    it "raises NameError" do
      expect { described_class::NOT_A_CONST }.to raise_error(NameError)
    end
  end
end
