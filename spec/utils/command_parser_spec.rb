# frozen_string_literal: true

RSpec.describe SheetFormatterBot::CommandParser do
  before do
    # Перезагружаем команды перед каждым тестом
    SheetFormatterBot::CommandParser.define_commands
  end

  describe ".dispatch" do
    let(:context) { double("TelegramBot") }
    let(:message) { double("Message", text: "/start", from: double("User", id: 123)) }

    it "dispatches a valid command to the correct handler" do
      expect(context).to receive(:handle_start).with(message, [])

      result = SheetFormatterBot::CommandParser.dispatch(message, context)
      expect(result).to be true
    end

    it "returns false for unrecognized commands" do
      allow(message).to receive(:text).and_return("/unknowncommand")
      expect(context).not_to receive(:handle_start)

      result = SheetFormatterBot::CommandParser.dispatch(message, context)
      expect(result).to be false
    end

    it "extracts parameters from commands" do
      allow(message).to receive(:text).and_return("/myname John Doe")
      expect(context).to receive(:handle_set_sheet_name).with(message, ["John Doe"])

      SheetFormatterBot::CommandParser.dispatch(message, context)
    end

    it "handles empty messages" do
      allow(message).to receive(:text).and_return("")
      expect(context).not_to receive(:handle_start)

      result = SheetFormatterBot::CommandParser.dispatch(message, context)
      expect(result).to be_nil
    end

    it "handles nil messages" do
      allow(message).to receive(:text).and_return(nil)
      expect(context).not_to receive(:handle_start)

      result = SheetFormatterBot::CommandParser.dispatch(message, context)
      expect(result).to be_nil
    end
  end

  describe ".help_text" do
    it "returns a string with all command descriptions" do
      help_text = SheetFormatterBot::CommandParser.help_text

      expect(help_text).to be_a(String)
      expect(help_text).to include("/start")
      expect(help_text).to include("/map")
      expect(help_text).to include("/myname")
      expect(help_text).to include("/mappings")
      expect(help_text).to include("/test")
    end
  end
end
