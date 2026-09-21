# frozen_string_literal: true

require_relative "lib/vouch/version"

Gem::Specification.new do |spec|
  spec.name = "rails_vouch"
  spec.version = Vouch::VERSION
  spec.authors = ["Nicolas J Jensen"]
  spec.email = ["nicolasjensen9@gmail.com"]
  spec.summary = "Warden-based authentication engine for Rails"
  spec.description = "A flexible authentication system with Warden strategies, " \
                     "OmniAuth integration, two-factor authentication, " \
                     "account locking, password history tracking, and invitations. " \
                     "Supports split-model (Account + Identity) and single-model patterns."
  spec.license = "MIT"
  spec.homepage = "https://github.com/NicolasJJensen/rails_vouch"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues"
  }

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "lib/**/*",
      "app/**/*",
      "config/**/*",
      "docs/credential-adapter-contract.md",
      "README.md",
      "CHANGELOG.md",
      "LICENSE.txt"
    ].select { |f| File.file?(f) }
  end

  spec.require_paths = ["lib"]

  spec.add_dependency "railties",      ">= 8.0", "< 9.0"
  spec.add_dependency "activerecord",  ">= 8.0", "< 9.0"
  spec.add_dependency "activesupport", ">= 8.0", "< 9.0"
  spec.add_dependency "actionpack",    ">= 8.0", "< 9.0"
  # head :unprocessable_content is only a valid status symbol from Rack 3.1.
  spec.add_dependency "rack",          ">= 3.1", "< 4.0"
  spec.add_dependency "active_hooks",  "~> 0.1"
  spec.add_dependency "warden",        "~> 1.2"
  spec.add_dependency "bcrypt",        "~> 3.1"
  spec.add_dependency "otp_courier",   "~> 0.1"

  spec.add_development_dependency "pg",                              "~> 1.1"
  spec.add_development_dependency "rspec-rails",                     "~> 7.0"
  spec.add_development_dependency "factory_bot_rails",               "~> 6.2"
  spec.add_development_dependency "faker",                           "~> 3.0"
  spec.add_development_dependency "omniauth-rails_csrf_protection",  ">= 1.0", "< 2.0"
end
