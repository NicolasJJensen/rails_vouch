# frozen_string_literal: true

# Contact verification for saved records and unsaved registration credentials.
# Saved challenges use row locks; temporary challenges retain attempts in their
# trusted serialized state and require shared controller rate limits.
#
module Vouch
  module Verifiable
    extend ActiveSupport::Concern
    include Vouch::LockoutCounter
    include Vouch::ChallengeNonce
    include Vouch::VerificationSubject
    include Vouch::VerificationState

    included do
      attr_accessor :challenge_token

      scope :verified,   -> { where.not(verified_at: nil) }
      scope :unverified, -> { where(verified_at: nil) }
    end

    def verified?
      verified_at.present?
    end

    def verification_locked?
      locked_window_open?(
        locked_at_attr:   :verification_locked_at,
        lockout_duration: verifiable_config.lockout_duration
      )
    end

    def start_verification
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

      Vouch::Result.ok(issued.token, record: self)
    rescue Vouch::Persistence::Cancelled, ActiveRecord::RecordNotSaved => error
      Vouch::Result.cancelled(record: self, error: error)
    rescue ActiveRecord::RecordInvalid => error
      Vouch::Result.invalid(record: self, error: error)
    end

    def start_verification!
      result = start_verification
      raise Vouch::OperationFailed, result unless result.ok?
      result
    end

    def complete_verification(code, token: challenge_token)
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
          transaction_result.is_a?(Vouch::Result) ? transaction_result : Vouch::Result.ok(self)
        else
          self[:verification_nonce] = nil
          self.verified_at = Time.current
          @verification_verified_subject = verifiable_subject
          @verification_verified_version = verifiable_subject_version
          @verification_verified_at = verified_at
          Vouch::Result.ok(self)
        end
      else
        # Do not attempt a lockout write while the caller has unpersisted
        # subject/version changes; Active Record cannot reload a dirty row
        # under a row lock, and the mismatch is already a failed challenge.
        return Vouch::Result.invalid if persisted? && has_changes_to_save?
        bump_verification_lockout!
        Vouch::Result.invalid
      end
    rescue Vouch::Persistence::Cancelled, ActiveRecord::RecordNotSaved => error
      Vouch::Result.cancelled(record: self, error: error)
    rescue ActiveRecord::RecordInvalid => error
      Vouch::Result.invalid(record: self, error: error)
    end

    def complete_verification!(code, token: challenge_token)
      result = complete_verification(code, token: token)
      raise Vouch::OperationFailed, result unless result.ok?
      result
    end

    def unverify
      attrs = { verified_at: nil }
      %i[verification_nonce confirmation_nonce two_factor_nonce sign_in_nonce].each do |name|
        attrs[name] = nil if has_attribute?(name)
      end
      if persisted?
        Vouch::Persistence.transaction(self) do
          lock!
          Vouch::Persistence.update!(self, attrs)
        end
      else
        assign_attributes(attrs)
      end
      Vouch::Result.ok(self)
    rescue Vouch::Persistence::Cancelled, ActiveRecord::RecordNotSaved => error
      Vouch::Result.cancelled(record: self, error: error)
    rescue ActiveRecord::RecordInvalid => error
      Vouch::Result.invalid(record: self, error: error)
    end

    def unverify!
      result = unverify
      raise Vouch::OperationFailed, result unless result.ok?
      result
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
      unless persisted?
        self.verification_attempts = verification_attempts.to_i + 1
        self.verification_locked_at = Time.current if verification_attempts >= verifiable_config.max_attempts
        return
      end

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
