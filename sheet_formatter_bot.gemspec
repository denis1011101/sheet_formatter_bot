# frozen_string_literal: true

require_relative "lib/sheet_formatter_bot/version"

Gem::Specification.new do |spec|
  spec.name = "sheet_formatter_bot"
  spec.version = SheetFormatterBot::VERSION
  spec.authors = ["TODO: Write your name"]
  spec.email = ["TODO: Write your email address"]

  spec.summary = "Telegram bot for edit tennis google table."
  spec.description = "This bot allows you to change the formatting (boldness, background, etc.) of cells in a given Google Sheet via Telegram commands."
  spec.homepage = "https://github.com/denis1011101/sheet_formatter_bot"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/denis1011101/sheet_formatter_bot"
  spec.metadata["changelog_uri"] = "https://github.com/denis1011101/sheet_formatter_bot"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
  #
  spec.add_dependency "telegram-bot-ruby", "~> 0.19"
  spec.add_dependency "google-apis-sheets_v4", "~> 0.44.0"
  spec.add_dependency "google-apis-core", "~> 0.18.0"
  spec.add_dependency "googleauth", "~> 1.2"
  spec.add_dependency "dotenv", "~> 2.8"
  spec.add_dependency "zeitwerk", "~> 2.6"

  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "rubocop", "~> 1.21"

  # Добавляем зависимости, которые были частью стандартной библиотеки
  spec.add_dependency "bigdecimal", "~> 3.1"
  spec.add_dependency "ostruct", "~> 0.5"
end
