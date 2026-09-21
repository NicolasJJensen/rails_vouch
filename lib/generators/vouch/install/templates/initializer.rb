# frozen_string_literal: true

# Vouch configuration.
#
# All values shown are defaults — uncomment and edit to override.
Vouch.configure do |config|
  # Login resolvers — order determines which gets first crack at params.
  config.register_login_resolver Vouch::LoginResolver::EmailResolver

  # Warden defaults.
  # config.warden_default_strategies = [:password]
  # config.warden_failure_app        = Vouch::FailureApp

  # Lockable.
  # config.lockable.max_failed_attempts = 5
  # config.lockable.lockout_duration    = 30.minutes
  # config.lockable.strategy            = :failed_attempts

  # Password reset tokens.
  # config.password_resetable.expiry = 15.minutes

  # Password history (anti-reuse).
  # config.password_trackable.history_count  = 5
  # config.password_trackable.history_window = 1.month

  # Two-factor.
  # config.two_factorable.max_attempts       = 5
  # config.two_factorable.lockout_duration   = 30.minutes
  # config.two_factorable.challenge_validity = 5.minutes
  # config.two_factorable.length             = 6

  # Invitations.
  # config.invitations.expiry = 7.days
end
