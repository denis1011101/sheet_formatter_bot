# frozen_string_literal: true

require "bundler/setup"
require "sheet_formatter_bot"
require "fileutils"
require "tmpdir"

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"

  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.after(:suite) do
    FileUtils.rm_rf(Dir.glob("#{Dir.tmpdir}/sheet_formatter_bot_test_*"))
  end
end
