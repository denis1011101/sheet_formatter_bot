# frozen_string_literal: true

RSpec.describe SheetFormatterBot::User do
  describe "initialization" do
    it "creates a new user with required attributes" do
      user = SheetFormatterBot::User.new(telegram_id: 123456)

      expect(user.telegram_id).to eq(123456)
      expect(user.username).to be_nil
      expect(user.first_name).to be_nil
      expect(user.last_name).to be_nil
      expect(user.sheet_name).to be_nil
      expect(user.tennis_role).to be_nil
      expect(user.registered_at).to be_a(Time)
    end

    it "creates a user with all attributes" do
      user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        username: "testuser",
        first_name: "Test",
        last_name: "User"
      )

      expect(user.telegram_id).to eq(123456)
      expect(user.username).to eq("testuser")
      expect(user.first_name).to eq("Test")
      expect(user.last_name).to eq("User")
    end
  end

  describe "#full_name" do
    it "returns the combined first and last name" do
      user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        first_name: "Test",
        last_name: "User"
      )

      expect(user.full_name).to eq("Test User")
    end

    it "returns just the first name when last name is nil" do
      user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        first_name: "Test"
      )

      expect(user.full_name).to eq("Test")
    end
  end

  describe "#display_name" do
    it "returns username if available" do
      user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        username: "testuser",
        first_name: "Test"
      )

      expect(user.display_name).to eq("testuser")
    end

    it "returns full name if username is not available" do
      user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        first_name: "Test",
        last_name: "User"
      )

      expect(user.display_name).to eq("Test User")
    end

    it "returns telegram_id as string if no username or name available" do
      user = SheetFormatterBot::User.new(telegram_id: 123456)

      expect(user.display_name).to eq("123456")
    end
  end

  describe ".from_telegram_user" do
    it "creates a user from a Telegram user object" do
      telegram_user = double(
        id: 123456,
        username: "testuser",
        first_name: "Test",
        last_name: "User"
      )

      user = SheetFormatterBot::User.from_telegram_user(telegram_user)

      expect(user.telegram_id).to eq(123456)
      expect(user.username).to eq("testuser")
      expect(user.first_name).to eq("Test")
      expect(user.last_name).to eq("User")
    end
  end
end
