# frozen_string_literal: true

require "tzinfo"
require "rspec"
require_relative "../../lib/sheet_formatter_bot/utils/time_utils"

RSpec.describe SheetFormatterBot::Utils::TimeUtils do
  include described_class

    describe "#parse_game_hour" do
    it "parses hour from valid time string" do
      expect(parse_game_hour("19:30")).to eq(19)
      expect(parse_game_hour("00:00")).to eq(0)
      expect(parse_game_hour("7:15")).to eq(7)
    end

    it "returns nil for nil or invalid input" do
      expect(parse_game_hour(nil)).to be_nil
      expect(parse_game_hour("")).to be_nil
      expect(parse_game_hour("abc")).to be_nil
      expect(parse_game_hour("25:61")).to eq(25)
    end
  end

  describe "#greeting_by_hour" do
    it "returns 'Доброе утро' for 5..11" do
      (5..11).each do |h|
        expect(greeting_by_hour(h)).to eq("Доброе утро")
      end
    end

    it "returns 'Добрый день' for 12..17" do
      (12..17).each do |h|
        expect(greeting_by_hour(h)).to eq("Добрый день")
      end
    end

    it "returns 'Добрый вечер' for 18..23" do
      (18..23).each do |h|
        expect(greeting_by_hour(h)).to eq("Добрый вечер")
      end
    end

    it "returns 'Здравствуй' for 0..4" do
      (0..4).each do |h|
        expect(greeting_by_hour(h)).to eq("Здравствуй")
      end
    end

    it "returns 'Здравствуй' for 24 and negative hours" do
      expect(greeting_by_hour(24)).to eq("Здравствуй")
      expect(greeting_by_hour(-1)).to eq("Здравствуй")
    end
  end

  describe "#parse_game_time" do
    let(:tz) { TZInfo::Timezone.get("Asia/Yekaterinburg") }

    it "parses date and time strings into a TZInfo::TimeWithZone" do
      result = parse_game_time("04.06.2025", "19:30", tz)
      expect(result.year).to eq(2025)
      expect(result.month).to eq(6)
      expect(result.day).to eq(4)
      expect(result.hour).to eq(19)
      expect(result.min).to eq(30)
      expect(result.zone).to eq("+05")
    end
  end

  describe "#hours_diff" do
    let(:tz) { TZInfo::Timezone.get("Asia/Yekaterinburg") }

    it "returns the rounded difference in hours between two times" do
      t1 = tz.local_time(2025, 6, 4, 19, 0)
      t2 = tz.local_time(2025, 6, 4, 17, 30)
      expect(hours_diff(t1, t2)).to eq(2)
      expect(hours_diff(t2, t1)).to eq(-2)
    end

    it "rounds to the nearest hour" do
      t1 = tz.local_time(2025, 6, 4, 19, 45)
      t2 = tz.local_time(2025, 6, 4, 18, 15)
      expect(hours_diff(t1, t2)).to eq(2)
    end
  end
end
