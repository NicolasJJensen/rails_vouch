# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_dispatch.show_exceptions = :rescuable
  config.action_controller.allow_forgery_protection = false
  config.active_support.deprecation = :stderr
  config.active_support.disallowed_deprecations_behavior = :raise
  config.active_storage.service = :test

  # Use MemoryStore so rate-limit counters don't persist between test runs.
  config.cache_store = :memory_store
end
