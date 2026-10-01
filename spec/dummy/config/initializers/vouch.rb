# frozen_string_literal: true

Vouch.configure do |config|
  config.lockable.max_failed_attempts = 5
  config.lockable.lockout_duration = 5.minutes

  config.login_resolvers = [Vouch::LoginResolver::EmailResolver]
end
