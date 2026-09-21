require_relative '../persistence'

# Account lockout with exponential backoff.
#
# After `auth_config(:lockable, :max_failed_attempts)` consecutive failures,
# the account is locked. Each successive lockout doubles in duration
# (capped at 2^8 * base).
#
# Required columns:
#   - failed_attempts (integer, default: 0)
#   - locked_at (datetime, nullable)
#   - consecutive_locks (bigint, default: 0, not null)
#
module Vouch
  module Lockable
    module Concern
      extend ActiveSupport::Concern

      MAX_LOCKOUT_EXPONENT = 8 # Cap: 2^8 = 256x base = ~21 hours max

      def current_lockout_duration
        exponent = (consecutive_locks - 1).clamp(0, MAX_LOCKOUT_EXPONENT)
        auth_config(:lockable, :lockout_duration) * (2**exponent)
      end

      def lockout_time_remaining
        return 0 unless locked?

        expiry_time = locked_at + current_lockout_duration
        ActiveSupport::Duration.build([0, expiry_time - Time.current].max.to_i)
      end

      def locked?
        locked_at.present? && locked_at > current_lockout_duration.ago
      end

      def lock_account!
        Vouch::Persistence.transaction(self) do
          lock!
          Vouch::Persistence.update!(self, locked_at: Time.current, consecutive_locks: consecutive_locks + 1)
        end
      end

      def successful_login!
        Vouch::Persistence.transaction(self) do
          lock!
          Vouch::Persistence.update!(self, failed_attempts: 0, locked_at: nil, consecutive_locks: 0)
        end
        super
        self
      end

      def failed_login!
        Vouch::Persistence.transaction(self) do
          lock!
          max_failed_attempts = auth_config(:lockable, :max_failed_attempts)
          new_attempts = failed_attempts + 1
          attrs = { failed_attempts: new_attempts }

          if auth_config(:lockable, :strategy) == :failed_attempts &&
             new_attempts >= max_failed_attempts && !locked?
            attrs[:locked_at] = Time.current
            attrs[:consecutive_locks] = consecutive_locks + 1
          end

          Vouch::Persistence.update!(self, attrs)
        end
        super
        self
      end

    end
  end
end
