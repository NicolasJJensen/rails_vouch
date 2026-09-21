# frozen_string_literal: true

Vouch.configure do |config|
  config.lockable.max_failed_attempts = 5
  config.lockable.lockout_duration = 5.minutes

  config.register_login_resolver Vouch::LoginResolver::EmailResolver
end
