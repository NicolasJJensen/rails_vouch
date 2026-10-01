# frozen_string_literal: true

require_relative "persistence"

# Recovery codes owned by an individual authenticator. Code storage comes
# from the host's backup_codes association; successful recovery retains the
# factor's identity but does not claim proof of its original delivery channel.
module Vouch
  module BackupCodable
    extend ActiveSupport::Concern

    # Installed ahead of both the host model and TwoFactorable so backup codes
    # are an alternate proof, not a fallback after a failed proof has already
    # consumed the final permitted attempt.
    module TwoFactorChallenge
      def verify_challenge(code, token:)
        return super if Vouch::BackupCodable.recovery_code_fallback_disabled?

        result = consume_recovery_code_result(code, count_failure: false)
        return result unless result.invalid?

        super
      end
    end

    class_methods do
      def install_two_factor_challenge_wrapper!
        return unless ancestors.include?(Vouch::TwoFactorable)
        return if ancestors.include?(Vouch::BackupCodable::TwoFactorChallenge)

        prepend Vouch::BackupCodable::TwoFactorChallenge
      end
    end

    class << self
      def without_recovery_code_fallback
        previous = Thread.current[:vouch_disable_recovery_code_fallback]
        Thread.current[:vouch_disable_recovery_code_fallback] = true
        yield
      ensure
        Thread.current[:vouch_disable_recovery_code_fallback] = previous
      end

      def recovery_code_fallback_disabled?
        Thread.current[:vouch_disable_recovery_code_fallback]
      end
    end

    included do
      install_two_factor_challenge_wrapper!
    end

    def generate_recovery_codes(count: Vouch.configuration.recovery_codes.code_count,
                                length: Vouch.configuration.recovery_codes.code_length)
      raise ArgumentError, "cannot generate recovery codes for an unpersisted record" unless persisted?

      plain = Vouch::RecoveryCodes.generate(count: count, length: length)
      Vouch::RecoveryCodes.replace!(self, relation: backup_codes, plaintexts: plain)
    rescue Vouch::Persistence::Cancelled => error
      Vouch::Result.cancelled(record: self, error: error)
    end

    def generate_recovery_codes!(**options)
      result = generate_recovery_codes(**options)
      raise Vouch::OperationFailed, result unless result.ok?
      result
    end
    alias_method :regenerate_backup_codes!, :generate_recovery_codes!

    def consume_recovery_code(submitted)
      consume_recovery_code_result(submitted, count_failure: true)
    end

    def consume_recovery_code!(submitted)
      result = consume_recovery_code(submitted)
      raise Vouch::OperationFailed, result unless result.ok?
      result
    end
    alias_method :consume_backup_code!, :consume_recovery_code!

    def backup_codes_remaining
      backup_codes.where(used_at: nil).count
    end
    alias_method :recovery_codes_remaining, :backup_codes_remaining

    def backup_codes_low?
      backup_codes_remaining < Vouch.configuration.recovery_codes.low_threshold
    end
    alias_method :recovery_codes_low?, :backup_codes_low?

    private

    def consume_recovery_code_result(submitted, count_failure:)
      raise ArgumentError, "cannot consume recovery codes for an unpersisted record" unless persisted?
      return Vouch::Result.locked(record: self) unless backup_code_factor_eligible?

      Vouch::RecoveryCodes.consume!(self, relation: backup_codes, submitted: submitted,
        eligible: -> { backup_code_factor_eligible? }, on_success: ->(_) {
          if backup_code_two_factor_credential?
            Vouch::Persistence.update!(self, two_factor_failed_attempts: 0,
              two_factor_locked_at: nil, two_factor_last_used_at: Time.current)
          end
        }, on_failure: -> {
          if count_failure && backup_code_two_factor_credential?
            config = two_factorable_config
            bump_lockout_counter!(counter_attr: :two_factor_failed_attempts,
              locked_at_attr: :two_factor_locked_at, max_attempts: config.max_attempts,
              lockout_duration: config.lockout_duration)
          end
        })
    end

    # Backup codes are an alternative proof for TwoFactorable credentials, but
    # they must not bypass that credential's current security state. Hosts
    # using BackupCodable independently do not expose these methods and keep
    # the original backup-code-only contract.
    def backup_code_factor_eligible?
      return true unless respond_to?(:two_factor_locked?) && respond_to?(:two_factor_enabled?)

      return false if two_factor_locked? || !two_factor_enabled?
      return true unless respond_to?(:verified?)

      verified?
    end

    def backup_code_two_factor_credential?
      respond_to?(:two_factor_locked?) && respond_to?(:two_factor_enabled?)
    end

  end
end
