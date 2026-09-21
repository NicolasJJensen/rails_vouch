# frozen_string_literal: true

require_relative "persistence"

# Recoverable concern — one-time recovery codes for account recovery when
# the user has lost access to their primary 2FA method.
#
# Attached to the host's user-equivalent model (probably Account). One set
# per user across all 2FA methods. BCrypt-hashed at rest, single-use,
# regenerable. Codes never expire — only `used_at` invalidates one.
#
# Required columns on the host (added by `bin/rails g vouch:recoverable`):
#   - recovery_attempts:bigint default: 0, null: false
#   - recovery_locked_at:datetime
#
# Required table: vouch_recovery_codes (also created by the
# generator). See Vouch::RecoveryCode.
#
# Public surface:
#   - #generate_recovery_codes!     => Result(Array<String>) (plaintext, ONCE)
#   - #consume_recovery_code!(code) => Result
#   - #recovery_codes_remaining     => Integer
#   - #recovery_codes_low?          => Boolean
#   - #recovery_locked?             => Boolean
#
# Concurrency: both generate and consume `lock!` the host row at the top of
# their transaction. Nothing else in the gem touches the recovery-code
# table directly, so deadlock risk is nil under normal operation.
# `ActiveRecord::Deadlocked` propagates if a host deadlocks against
# concurrent writers; the host owns retry policy.
#
module Vouch
  module Recoverable
    extend ActiveSupport::Concern
    include Vouch::LockoutCounter

    # Crockford alphabet (no I, L, O, U, 0, 1) — matches otp_courier's
    # alphanumeric charset.
    CROCKFORD_CHARS = "ABCDEFGHJKMNPQRSTVWXYZ23456789".chars.freeze

    included do
      has_many :vouch_recovery_codes,
               class_name:  "Vouch::RecoveryCode",
               as:          :recoverable,
               dependent:   :destroy
    end

    def recovery_locked?
      locked_window_open?(
        locked_at_attr:   :recovery_locked_at,
        lockout_duration: recoverable_value(:lockout_duration)
      )
    end

    def recovery_codes_remaining
      vouch_recovery_codes.unused.count
    end

    def recovery_codes_low?
      recovery_codes_remaining < recoverable_value(:low_threshold)
    end

    # Generate a fresh set of recovery codes. Deletes any existing rows
    # (used or unused). Returns the plaintext set — caller MUST display
    # them immediately; the gem never reproduces them.
    def generate_recovery_codes!
      plaintexts = Array.new(recoverable_value(:code_count)) { generate_recovery_plaintext }
      # BCrypt is intentionally done before taking the host-row lock. Code
      # generation can be expensive and should not hold up auth operations.
      digests = plaintexts.map { |code| BCrypt::Password.create(code) }

      Vouch::Persistence.transaction(self) do
        # Serialize against concurrent consume_recovery_code! on this host.
        lock!

        vouch_recovery_codes.delete_all

        digests.each do |digest|
          Vouch::Persistence.create!(vouch_recovery_codes, code_digest: digest)
        end

        Vouch::Persistence.update!(self, recovery_attempts: 0, recovery_locked_at: nil)
      end

      Vouch::Result.ok(plaintexts.map { |code| format_recovery_code(code) })
    end

    # Consume a single recovery code. Returns Result.ok on success (marks
    # `used_at`, clears the attempt counter), Result.invalid on a miss, or
    # Result.locked while the recovery lockout is active.
    #
    # `code` is normalized: ALL whitespace stripped (handles "ab cd-ef 12"
    # pasted from a wrapped email), then hyphens dropped,
    # then upcase. Blank input returns Result.invalid.
    def consume_recovery_code!(code)
      return Vouch::Result.locked if recovery_locked?

      normalized = code.to_s.gsub(/\s/, "").delete("-").upcase

      Vouch::Persistence.transaction(self) do
        # Lock the host row for the whole transaction so the counter
        # increment below is race-free against concurrent attempts.
        lock!

        # A request may have waited for another failed attempt to lock this
        # account. Recheck after acquiring the row lock.
        next Vouch::Result.locked if recovery_locked?

        if normalized.empty?
          bump_failed_recovery_attempt!
          next Vouch::Result.invalid
        end

        # SELECT FOR UPDATE — held until COMMIT. Two concurrent submissions
        # of the same code can't both flip used_at.
        unused = vouch_recovery_codes
                   .where(used_at: nil)
                   .lock("FOR UPDATE")
                   .to_a

        # BCrypt::Errors::InvalidHash propagates intentionally: a corrupted
        # code_digest column means database integrity is compromised.
        match = unused.find { |row| BCrypt::Password.new(row.code_digest) == normalized }

        if match
          Vouch::Persistence.update!(match, used_at: Time.current)
          Vouch::Persistence.update!(self, recovery_attempts: 0, recovery_locked_at: nil)
          Vouch::Result.ok(match)
        else
          bump_failed_recovery_attempt!
          Vouch::Result.invalid
        end
      end
    rescue Vouch::Persistence::Cancelled
      Vouch::Result.cancelled
    end

    private

    def recoverable_config
      Vouch.configuration.recoverable
    end

    def recoverable_value(attribute)
      if respond_to?(:auth_config)
        auth_config(:recoverable, attribute)
      else
        recoverable_config.public_send(attribute)
      end
    end

    # Recoverable inlines the bump. The outer transaction
    # already holds `lock!` on the host row, so wrapping another `with_lock`
    # via LockoutCounter#bump_lockout_counter! would be redundant.
    def bump_failed_recovery_attempt!
      attributes = {recovery_attempts: recovery_attempts + 1}
      attributes[:recovery_locked_at] = Time.current if attributes[:recovery_attempts] >= recoverable_value(:max_attempts)
      Vouch::Persistence.update!(self, attributes)
    end

    def generate_recovery_plaintext
      Array.new(recoverable_value(:code_length)) do
        CROCKFORD_CHARS.fetch(SecureRandom.random_number(CROCKFORD_CHARS.length))
      end.join
    end

    # Display format: split into two halves with a hyphen, e.g. "AB12-CD34".
    # Storage compares against the dehyphenated form (see consume_recovery_code!).
    def format_recovery_code(plaintext)
      mid = plaintext.length / 2
      "#{plaintext[0, mid]}-#{plaintext[mid..]}"
    end
  end
end
