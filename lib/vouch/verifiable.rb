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

    included do
      class_attribute :verifiable_subject_attribute, instance_writer: false

      attr_accessor :challenge_token

      # A credential subject is mutable in many host applications.  Track
      # changes before persistence as well as on persisted rows so a draft
      # cannot be verified with a challenge issued for an earlier value.
      after_initialize :mark_verifiable_subject_ready
      before_update :synchronize_verification_subject_version

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
      return Vouch::Result.locked if verification_locked?

      code = code.to_s.strip

      payload = consume_otp_token(token, code, Vouch::Purposes.verify(self))

      if verifiable_payload_valid?(payload)
        if persisted?
          transaction_result = Vouch::Persistence.transaction(self) do
            lock!
            next Vouch::Result.invalid if verification_locked?
            next Vouch::Result.invalid unless verifiable_payload_valid?(payload)

            Vouch::Persistence.update!(self,
              verification_nonce:     nil,
              verified_at:            Time.current,
              verification_attempts:  0,
              verification_locked_at: nil
            )
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
        attrs[:two_factor_nonce] = nil if has_attribute?(:two_factor_nonce)
        attrs[:sign_in_nonce] = nil if has_attribute?(:sign_in_nonce)
        Vouch::Persistence.update!(self, attrs)
      end
      self
    end

    # The current natural identifier for both persisted and draft records.
    # The row id remains part of the OTP purpose for persisted records, while
    # the payload binds a challenge to the mutable subject value itself.
    def verifiable_subject
      attr = self.class.verifiable_subject_attribute
      # Persisted hosts that do not declare a natural subject keep the
      # historical id-bound behavior. Mutable credentials should declare the
      # subject attribute so edits invalidate their challenges.
      return id.to_s if !attr && persisted?

      raise NotImplementedError, <<~MSG.squish unless attr
        #{self.class.name} cannot compute a verifiable subject. Declare the
        natural identifier with `self.verifiable_subject_attribute = :your_attr`
        (e.g. :address for Email, :e164 for Phone, :label for Totp).
      MSG

      public_send(attr).to_s
    end

    # Host delivery hook. Override in the including model.
    def deliver_verification_code(_code)
      raise Vouch::ConfigurationError,
        "#{self.class.name} must implement #deliver_verification_code(code)"
    end

    private

    # Keep the challenge version in the token payload. The migration supplied
    # by the generator adds this required column; drafts use the same row
    # attribute before they are persisted.
    def verifiable_subject_version
      self[:verification_version].to_i
    end

    def mark_verifiable_subject_ready
      @verifiable_subject_ready = true
    end

    # Active Record calls this method for every generated attribute writer. It
    # lets drafts detect A -> B -> A changes before a save callback runs.
    public
    # `record[:subject] = value` goes through `write_attribute`, while
    # generated setters and `assign_attributes` may call `_write_attribute`
    # directly depending on the Active Record version. Track both entry
    # points while suppressing the nested callback.
    def write_attribute(attr_name, value)
      track_verifiable_subject_write(attr_name, value)
      @verifiable_subject_write_tracked = true
      super
    ensure
      @verifiable_subject_write_tracked = false
    end

    def _write_attribute(attr_name, value)
      track_verifiable_subject_write(attr_name, value) unless @verifiable_subject_write_tracked
      super
    end

    private

    def track_verifiable_subject_write(attr_name, value)
      subject_attribute = canonical_verifiable_subject_attribute
      return unless @verifiable_subject_ready && subject_attribute
      canonical_attribute = self.class.attribute_aliases[attr_name.to_s] || attr_name.to_s
      return unless canonical_attribute == subject_attribute
      return if read_attribute(canonical_attribute).to_s == value.to_s

      invalidate_verification_for_subject_change!
    end

    def canonical_verifiable_subject_attribute
      subject_attribute = self.class.verifiable_subject_attribute
      return unless subject_attribute

      self.class.attribute_aliases[subject_attribute.to_s] || subject_attribute.to_s
    end

    def invalidate_verification_for_subject_change!
      return if @invalidating_verifiable_subject

      @invalidating_verifiable_subject = true
      self[:verification_version] = verifiable_subject_version + 1

      self[:verified_at] = nil if has_attribute?("verified_at")
    ensure
      @invalidating_verifiable_subject = false
    end

    # A stale object may be saved concurrently with another subject update.
    # Lock the current row before choosing the next version so both updates
    # advance the persisted counter instead of writing the same N + 1 value.
    def synchronize_verification_subject_version
      subject_attribute = canonical_verifiable_subject_attribute
      subject_changed = subject_attribute && will_save_change_to_attribute?(subject_attribute)
      version_changed = will_save_change_to_attribute?(:verification_version)
      return true unless subject_changed || version_changed

      database_version = attribute_in_database(:verification_version).to_i
      local_delta = [self[:verification_version].to_i - database_version, 1].max
      latest_version = self.class.where(self.class.primary_key => id).lock.pick(:verification_version).to_i
      self[:verification_version] = latest_version + local_delta
      self[:verified_at] = nil if subject_changed
      true
    end

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
