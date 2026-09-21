# frozen_string_literal: true

require_relative 'boot'

require 'logger'
require 'rails/all'

Bundler.require(*Rails.groups)
require 'rails_vouch'

module Dummy
  class Application < Rails::Application
    config.load_defaults 7.0
    config.eager_load = false

    # Auth needs sessions and cookies (not API-only)
    config.api_only = false

    config.secret_key_base = "test_secret_key_base_for_vouch_dummy_app"

    # Ensure Rails.root points at the dummy app, not the gem root
    config.root = File.expand_path('..', __dir__)
  end
end
