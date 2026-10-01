# frozen_string_literal: true

module Vouch
  # Rails permits requests when a cache increment returns nil. Verification
  # must stop instead when its shared abuse counter is unavailable.
  class VerificationRateLimitStore
    class Unavailable < StandardError; end

    def initialize(store)
      if store.is_a?(ActiveSupport::Cache::NullStore) || store.is_a?(ActiveSupport::Cache::MemoryStore)
        raise ArgumentError, "Verification rate limits require a shared atomic cache store"
      end
      @store = store
    end

    def increment(name, amount, **options)
      count = @store.increment(name, amount, **options)
      raise Unavailable, "Verification rate-limit counter is unavailable" unless count.is_a?(Integer) && count.positive?

      count
    end
  end
end
