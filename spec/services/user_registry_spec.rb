# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe SheetFormatterBot::UserRegistry do
  let(:temp_dir) { File.join(Dir.tmpdir, "sheet_formatter_bot_test_#{Time.now.to_i}") }
  let(:storage_path) { File.join(temp_dir, "users.json") }
  let(:mapping_path) { File.join(temp_dir, "name_mapping.json") }
  let(:backup_dir) { File.join(temp_dir, "backups") }

  before do
    FileUtils.mkdir_p(temp_dir)
    FileUtils.mkdir_p(backup_dir)
  end

  after do
    FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
  end

  let(:registry) {
    SheetFormatterBot::UserRegistry.new(storage_path, mapping_path, backup_dir)
  }

  describe "#register_user" do
    it "registers a new user" do
      user = SheetFormatterBot::User.new(telegram_id: 123456)

      registry.register_user(user)

      expect(registry.find_by_telegram_id(123456)).to eq(user)
      expect(File.exist?(storage_path)).to be true
    end

    it "overwrites an existing user with the same ID" do
      user1 = SheetFormatterBot::User.new(
        telegram_id: 123456,
        username: "old_user"
      )
      user2 = SheetFormatterBot::User.new(
        telegram_id: 123456,
        username: "new_user"
      )

      registry.register_user(user1)
      registry.register_user(user2)

      found_user = registry.find_by_telegram_id(123456)
      expect(found_user).to eq(user2)
      expect(found_user.username).to eq("new_user")
    end
  end

  describe "#map_sheet_name_to_user" do
    it "maps a sheet name to a user" do
      user = SheetFormatterBot::User.new(telegram_id: 123456)
      registry.register_user(user)

      registry.map_sheet_name_to_user("John", 123456)

      expect(user.sheet_name).to eq("John")
      expect(registry.find_by_sheet_name("John")).to eq(user)
      expect(File.exist?(mapping_path)).to be true
    end
  end

  describe "#find_by_name" do
    before do
      @user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        username: "testuser",
        first_name: "Test",
        last_name: "User"
      )
      registry.register_user(@user)
      registry.map_sheet_name_to_user("TestSheet", 123456)
    end

    it "finds a user by sheet name" do
      expect(registry.find_by_name("TestSheet")).to eq(@user)
    end

    it "finds a user by first name" do
      expect(registry.find_by_name("Test")).to eq(@user)
    end

    it "finds a user by full name" do
      expect(registry.find_by_name("Test User")).to eq(@user)
    end

    it "finds a user by username" do
      expect(registry.find_by_name("testuser")).to eq(@user)
    end

    it "returns nil for unknown name" do
      expect(registry.find_by_name("Unknown")).to be_nil
    end
  end

  describe "#find_by_telegram_username" do
    before do
      @user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        username: "testuser"
      )
      registry.register_user(@user)
    end

    it "finds a user by username" do
      expect(registry.find_by_telegram_username("testuser")).to eq(@user)
    end

    it "finds a user by username with @ prefix" do
      expect(registry.find_by_telegram_username("@testuser")).to eq(@user)
    end

    it "is case insensitive" do
      expect(registry.find_by_telegram_username("TestUser")).to eq(@user)
    end
  end

  describe "#create_backup" do
    it "creates backup files" do
      user = SheetFormatterBot::User.new(telegram_id: 123456)
      registry.register_user(user)
      registry.map_sheet_name_to_user("TestName", 123456)

      registry.create_backup

      user_backups = Dir.glob(File.join(backup_dir, 'users_*.json'))
      mapping_backups = Dir.glob(File.join(backup_dir, 'name_mapping_*.json'))

      expect(user_backups).not_to be_empty
      expect(mapping_backups).not_to be_empty
    end
  end

  describe "file persistence" do
    it "reloads user data from files" do
      user = SheetFormatterBot::User.new(
        telegram_id: 123456,
        username: "testuser",
        first_name: "Test",
        last_name: "User"
      )
      registry.register_user(user)
      registry.map_sheet_name_to_user("TestName", 123456)

      # Create a new registry to test loading from files
      new_registry = SheetFormatterBot::UserRegistry.new(storage_path, mapping_path, backup_dir)

      loaded_user = new_registry.find_by_telegram_id(123456)
      expect(loaded_user).not_to be_nil
      expect(loaded_user.telegram_id).to eq(123456)
      expect(loaded_user.username).to eq("testuser")
      expect(loaded_user.sheet_name).to eq("TestName")
    end
  end
end
