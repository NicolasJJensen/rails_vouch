# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'

require File.expand_path('dummy/config/environment', __dir__)

abort("The Rails environment is running in production mode!") if Rails.env.production?

require 'rspec/rails'
require 'factory_bot_rails'

BCrypt::Engine.cost = BCrypt::Engine::MIN_COST

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

require 'warden/test/helpers'

module RequestAuthHelpers
  include Warden::Test::Helpers

  def sign_in(user)
    login_as(user, scope: :user)
  end

  def sign_in_as_account(account)
    Warden.on_next_request do |proxy|
      context = Vouch::PendingAuthentication.build(account,
        identities: Vouch.mapping_for(:user).identities_for(account), method: :password, hook: :sign_in)
      proxy.set_user(account, scope: :user_account, store: true)
      proxy.raw_session[Vouch::Session.key_for(:user, :selection)] = context
    end
  end
end

RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods
  config.include ActiveSupport::Testing::TimeHelpers
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  # Force route loading so Vouch.mappings[:user] is populated.
  # Routes are drawn lazily; without this, lib specs that reference
  # Vouch.mapping_for(:user) would fail.
  config.before(:suite) do
    Rails.application.routes.routes
  end

  # Clear the cache between examples so rate-limit counters don't
  # accumulate across tests within a single suite run.
  config.before(:each) do
    Rails.cache.clear
  end

  config.include RequestAuthHelpers, type: :request
  config.after(:each, type: :request) { Warden.test_reset! }
end
