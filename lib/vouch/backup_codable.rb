# frozen_string_literal: true

require_relative "persistence"

# BackupCodable concern — single-use recovery codes attached to a 2FA
# credential. Applied to TOTP models where "lost device" is the recovery
# scenario; any code in the current set substitutes for a TOTP code.
#
# Not applicable to Phone/Email 2FA — for those, recovery is credential
# replacement (verify a new phone/email), not code fallback.
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
        result = consume_backup_code!(code)
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

    included do
      install_two_factor_challenge_wrapper!
    end

    def regenerate_backup_codes!(count: backup_codable_config.code_count,
                                 bytes: backup_codable_config.code_bytes)
      raise ArgumentError, "cannot regenerate backup codes for an unpersisted record" unless persisted?

      plain = Array.new(count) { SecureRandom.hex(bytes) }
      digests = plain.map { |code| BCrypt::Password.create(code) }

      Vouch::Persistence.transaction(self) do
        # Serialize regeneration with consumption so a concurrent request
        # cannot consume a row from a set that is being replaced.
        lock!
        backup_codes.destroy_all
        digests.each do |digest|
          Vouch::Persistence.create!(backup_codes, code_digest: digest)
        end
      end

      Vouch::Result.ok(plain)
    end

    def consume_backup_code!(submitted)
      raise ArgumentError, "cannot consume backup codes for an unpersisted record" unless persisted?
      return Vouch::Result.locked unless backup_code_factor_eligible?

      submitted = submitted.to_s.strip
      return Vouch::Result.invalid if submitted.empty?

      Vouch::Persistence.transaction(self) do
        lock!
        next Vouch::Result.locked unless backup_code_factor_eligible?

        # Lock candidate rows before comparing and marking them used. A pair
        # of concurrent submissions must not both pass the unused check.
        rows = backup_codes.where(used_at: nil).lock.to_a
        match = rows.find { |row| BCrypt::Password.new(row.code_digest) == submitted }
        if match
          Vouch::Persistence.update!(match, used_at: Time.current)
          if backup_code_two_factor_credential?
            Vouch::Persistence.update!(self,
              two_factor_failed_attempts: 0,
              two_factor_locked_at:       nil,
              two_factor_last_used_at:    Time.current
            )
          end
          Vouch::Result.ok(match)
        else
          Vouch::Result.invalid
        end
      end
    rescue Vouch::Persistence::Cancelled
      Vouch::Result.cancelled
    end

    def backup_codes_remaining
      backup_codes.where(used_at: nil).count
    end

    def backup_codes_low?
      backup_codes_remaining < backup_codable_config.warn_at_remaining
    end

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
