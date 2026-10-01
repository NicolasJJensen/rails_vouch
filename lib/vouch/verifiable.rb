# frozen_string_literal: true

# Verifiable concern — challenge-response verification for contactable
# channels (Email, Phone) and pairing targets (AuthenticatorCode at
# enrollment).
#
# Supports two flows:
#
#   1. Persisted records — the row exists on disk, lockout counters live on
#      the row, and `complete_verification!` writes verified_at with a lock.
#
#   2. Drafts (unpersisted records) — used at registration time when
#      credentials are stashed in session before the account exists. Lockout
#      is a no-op (no columns to write). `complete_verification!` sets
#      verified_at in memory and returns; the caller persists later.
#
# State on the row (persisted flow only):
#   - verified_at:datetime
#   - verification_attempts:bigint default: 0, null: false
#   - verification_locked_at:datetime
#   - verification_version:bigint default: 0, null: false
#   - verification_nonce:string (nullable)
#   - created_at:datetime (validated when the feature is used)
#
# Public surface:
#   - .verifiable_subject_attribute        (class DSL — required)
#   - #verified?, #verification_locked?
#   - #start_verification!                 => Result.ok(token) | Result.locked
#   - #complete_verification!(code, token:) => Result
#   - #unverify!                           (clears verified_at)
#   - #verifiable_subject                  (id for persisted, natural id for drafts)
#   - #challenge_token                     (last issued token; survives session round-trip)
#
# Hosts may override #deliver_verification_code(code).
#
module Vouch
  module Verifiable
    extend ActiveSupport::Concern
    include Vouch::LockoutCounter
    include Vouch::ChallengeNonce
    include Vouch::VerificationSubject

    included do
      attr_accessor :challenge_token

      scope :verified,   -> { where.not(verified_at: nil) }
      scope :unverified, -> { where(verified_at: nil) }
    end

    def verified?
      verified_at.present?
    end

    # Drafts have no columns to lock against — always false.
    def verification_locked?
      return false unless persisted?

      locked_window_open?(
        locked_at_attr:   :verification_locked_at,
        lockout_duration: verifiable_config.lockout_duration
      )
    end

    # Issue a fresh verification challenge. Works for drafts and persisted
    # records. Sets `challenge_token` on the model so the token survives
    # session serialization for drafts. Delivery exceptions bubble.
    def start_verification!
      self.class.validate_auth_schema!(*Vouch::FeatureContracts.columns_for(:verifiable, self.class))
      reload if persisted? && !has_changes_to_save?
      return Vouch::Result.already_verified(self) if persisted? && verified?
      return Vouch::Result.locked if verification_locked?

      nonce = issue_nonce!(:verification_nonce)
      issued = OtpCourier::OTP.issue(
        purpose:  Vouch::Purposes.verify(self),
        payload:  { "nonce" => nonce, "subject" => verifiable_subject,
                    "version" => verifiable_subject_version,
                    "klass" => self.class.name },
        validity: verifiable_config.validity,
        length:   verifiable_config.length
      )

      self.challenge_token = issued.token

      deliver_verification_code(issued.code)

      Vouch::Result.ok(issued.token)
    end

    # Verify a submitted code. Persisted records get row-locked writes and
    # attempt-counter bumps. Drafts set verified_at in memory only — the
    # caller persists later (e.g. atomically alongside the parent record).
    def complete_verification!(code, token: challenge_token)
      self.class.validate_auth_schema!(*Vouch::FeatureContracts.columns_for(:verifiable, self.class))
      reload if persisted? && !has_changes_to_save?
      return Vouch::Result.already_verified(self) if persisted? && verified?
      return Vouch::Result.locked if verification_locked?

      code = code.to_s.strip

      payload = consume_otp_token(token, code, Vouch::Purposes.verify(self))

      if verifiable_payload_valid?(payload)
        if persisted?
          transaction_result = Vouch::Persistence.transaction(self) do
            lock!
            next Vouch::Result.already_verified(self) if verified?
            next Vouch::Result.invalid if verification_locked?
            next Vouch::Result.invalid unless verifiable_payload_valid?(payload)

            attrs = {
              verification_nonce:     nil,
              verified_at:            Time.current,
              verification_attempts:  0,
              verification_locked_at: nil
            }
            attrs[:confirmation_nonce] = nil if has_attribute?(:confirmation_nonce)
            Vouch::Persistence.update!(self, attrs)
          end
          transaction_result.is_a?(Vouch::Result) ? transaction_result : Vouch::Result.ok
        else
          self[:verification_nonce] = nil
          self.verified_at = Time.current
          @verification_verified_subject = verifiable_subject
          Vouch::Result.ok
        end
      else
        # Do not attempt a lockout write while the caller has unpersisted
        # subject/version changes; Active Record cannot reload a dirty row
        # under a row lock, and the mismatch is already a failed challenge.
        return Vouch::Result.invalid if persisted? && has_changes_to_save?
        bump_verification_lockout! if persisted?
        Vouch::Result.invalid
      end
    rescue Vouch::Persistence::Cancelled
      Vouch::Result.cancelled
    end

    def unverify!
      Vouch::Persistence.transaction(self) do
        lock!
        attrs = {verified_at: nil, verification_nonce: nil}
        attrs[:confirmation_nonce] = nil if has_attribute?(:confirmation_nonce)
        attrs[:two_factor_nonce] = nil if has_attribute?(:two_factor_nonce)
        attrs[:sign_in_nonce] = nil if has_attribute?(:sign_in_nonce)
        Vouch::Persistence.update!(self, attrs)
      end
      self
    end

    # Host delivery hook. Override in the including model.
    def deliver_verification_code(_code)
      raise Vouch::ConfigurationError,
        "#{self.class.name} must implement #deliver_verification_code(code)"
    end

    private

    # Subject-based payload check. Differs from LockoutCounter#payload_valid?
    # (which compares by id) so drafts, which have no id, can be verified by
    # their natural identifier. Method is Verifiable-specific to avoid
    # colliding with the shared payload_valid? used by TwoFactorable.
    def verifiable_payload_valid?(payload)
      nonce_matches?(payload, :verification_nonce) &&
        payload["subject"] == verifiable_subject &&
        payload["version"].is_a?(Integer) &&
        payload["version"] == verifiable_subject_version &&
        payload["klass"] == self.class.name
    end

    def bump_verification_lockout!
      bump_lockout_counter!(
        counter_attr:     :verification_attempts,
        locked_at_attr:   :verification_locked_at,
        max_attempts:     verifiable_config.max_attempts,
        lockout_duration: verifiable_config.lockout_duration
      )
    end

    def verifiable_config
      Vouch.configuration.verifiable
    end
  end
end
