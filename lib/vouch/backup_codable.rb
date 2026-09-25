# frozen_string_literal: true

require_relative "persistence"

# BackupCodable concern — single-use recovery codes attached to any
# TwoFactorable credential. A set belongs to its credential owner, so an
# application may enable it for a phone, email, authenticator, or another
# factor independently of account-owned recovery codes.
#
# The host declares the has_many association; the concern assumes it's
# named :backup_codes and points at a model with `code_digest:string` and
# `used_at:datetime` columns.
#
#   class Totp < ApplicationRecord
#     include Vouch::TwoFactorable
#     include Vouch::BackupCodable
#     has_many :backup_codes, class_name: "TotpBackupCode", dependent: :destroy
#   end
#
# Public surface:
#   - #regenerate_backup_codes! => Result(Array<String>) (plaintext, shown once)
#   - #consume_backup_code!(code) => Result        (marks used on match)
#   - #backup_codes_remaining => Integer
#   - #backup_codes_low? => Boolean                (< warn_at_remaining)
#
    # When this concern and TwoFactorable are both included, a private wrapper
    # consumes valid backup codes before the host's primary verifier runs.
#
module Vouch
  module BackupCodable
    extend ActiveSupport::Concern

    # Installed ahead of both the host model and TwoFactorable so backup codes
    # are an alternate proof, not a fallback after a failed proof has already
    # consumed the final permitted attempt.
    module TwoFactorChallenge
      def verify_challenge(code, token:)
        return super if Vouch::BackupCodable.recovery_code_fallback_disabled?

        result = consume_recovery_code!(code)
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

    def generate_recovery_codes!(count: backup_codable_config.code_count,
                                 bytes: backup_codable_config.code_bytes)
      raise ArgumentError, "cannot regenerate backup codes for an unpersisted record" unless persisted?

      plain = Array.new(count) { SecureRandom.hex(bytes) }
      Vouch::RecoveryCodes.replace!(self, relation: backup_codes, plaintexts: plain)
    end
    alias_method :regenerate_backup_codes!, :generate_recovery_codes!

    def consume_recovery_code!(submitted)
      raise ArgumentError, "cannot consume backup codes for an unpersisted record" unless persisted?
      return Vouch::Result.locked unless backup_code_factor_eligible?

      Vouch::RecoveryCodes.consume!(self, relation: backup_codes, submitted: submitted,
        eligible: -> { backup_code_factor_eligible? }, on_success: ->(_) {
          if backup_code_two_factor_credential?
            Vouch::Persistence.update!(self, two_factor_failed_attempts: 0,
              two_factor_locked_at: nil, two_factor_last_used_at: Time.current)
          end
        })
    end
    alias_method :consume_backup_code!, :consume_recovery_code!

    def backup_codes_remaining
      backup_codes.where(used_at: nil).count
    end
    alias_method :recovery_codes_remaining, :backup_codes_remaining

    def backup_codes_low?
      backup_codes_remaining < backup_codable_config.warn_at_remaining
    end
    alias_method :recovery_codes_low?, :backup_codes_low?

    private

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

    def backup_codable_config
      Vouch.configuration.backup_codable
    end
  end
end
