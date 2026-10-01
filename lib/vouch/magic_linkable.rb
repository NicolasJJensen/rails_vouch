# frozen_string_literal: true

# Passwordless first-factor codes for saved credentials. A successful proof
# must pass through complete_sign_in; it does not publish a Warden session or
# become MFA evidence by itself.
module Vouch
  module MagicLinkable
    extend ActiveSupport::Concern
    include Vouch::LockoutCounter
    include Vouch::ChallengeNonce
    include Vouch::VerificationSubject

    def sign_in_locked?
      locked_window_open?(
        locked_at_attr:   :sign_in_locked_at,
        lockout_duration: magic_linkable_config.lockout_duration
      )
    end

    # Issue a one-time sign-in code. Requires a persisted credential —
    # you can't sign in with an unsaved row. Delivery exceptions raised
    # by `deliver_sign_in_code` bubble; hosts rescue at the controller
    # level, same convention as Verifiable.
    def issue_sign_in_code
      self.class.validate_auth_schema!(*Vouch::FeatureContracts.columns_for(:magic_linkable, self.class))
      raise ArgumentError, "cannot sign in with an unpersisted record" unless persisted?
      return Vouch::Result.locked if sign_in_locked?

      nonce = issue_nonce!(:sign_in_nonce)
      issued = OtpCourier::OTP.issue(
        purpose:  Vouch::Purposes.sign_in(self),
        payload:  sign_in_payload.merge("nonce" => nonce),
        validity: magic_linkable_config.validity,
        length:   magic_linkable_config.length
      )

      deliver_sign_in_code(issued.code)

      Vouch::Result.ok(issued.token, record: self)
    rescue Vouch::Persistence::Cancelled, ActiveRecord::RecordNotSaved => error
      Vouch::Result.cancelled(record: self, error: error)
    rescue ActiveRecord::RecordInvalid => error
      Vouch::Result.invalid(record: self, error: error)
    end

    def issue_sign_in_code!
      result = issue_sign_in_code
      raise Vouch::OperationFailed, result unless result.ok?
      result
    end

    # Verify a submitted sign-in code. Does NOT set verified_at (that's
    # Verifiable's job) or two_factor_last_used_at (that's TwoFactorable's).
    # Returns a proof outcome; the controller then completes authentication.
    def verify_sign_in_code(code, token:)
      raise ArgumentError, "cannot sign in with an unpersisted record" unless persisted?
      self.class.validate_auth_schema!(*Vouch::FeatureContracts.columns_for(:magic_linkable, self.class))
      return Vouch::Result.locked if sign_in_locked?

      code = code.to_s.strip

      payload = consume_otp_token(token, code, Vouch::Purposes.sign_in(self))

      if sign_in_payload_valid?(payload)
        transaction_result = Vouch::Persistence.transaction(self) do
          lock!
          next Vouch::Result.locked if sign_in_locked?
          next Vouch::Result.invalid unless sign_in_payload_valid?(payload)

          Vouch::Persistence.update!(self, sign_in_attempts: 0, sign_in_locked_at: nil, sign_in_nonce: nil)
        end
        transaction_result.is_a?(Vouch::Result) ? transaction_result : Vouch::Result.ok(self)
      else
        bump_lockout_counter!(
          counter_attr:     :sign_in_attempts,
          locked_at_attr:   :sign_in_locked_at,
          max_attempts:     magic_linkable_config.max_attempts,
          lockout_duration: magic_linkable_config.lockout_duration
        )
        Vouch::Result.invalid
      end
    rescue Vouch::Persistence::Cancelled, ActiveRecord::RecordNotSaved => error
      Vouch::Result.cancelled(record: self, error: error)
    rescue ActiveRecord::RecordInvalid => error
      Vouch::Result.invalid(record: self, error: error)
    end

    def verify_sign_in_code!(code, token:)
      result = verify_sign_in_code(code, token: token)
      raise Vouch::OperationFailed, result unless result.ok?
      result
    end

    # Host delivery hook. Override per credential type:
    #
    #   def deliver_sign_in_code(code)
    #     SmsCourier.send(e164, "Your sign-in code: #{code}")
    #   end
    #
    def deliver_sign_in_code(_code)
      raise Vouch::ConfigurationError,
        "#{self.class.name} must implement #deliver_sign_in_code(code)"
    end

    private

    # Mutable contact credentials commonly combine MagicLinkable with
    # Verifiable. Bind sign-in challenges to the same subject/version in that
    # case so changing the address or phone invalidates outstanding links.
    def sign_in_payload
      payload = { "id" => Vouch::RecordKey.value(self), "klass" => self.class.name }
      if respond_to?(:verifiable_subject)
        payload["subject"] = verifiable_subject
        payload["version"] = verifiable_subject_version
      end
      payload
    end

    def sign_in_payload_valid?(payload)
      return false unless payload_valid?(payload) && nonce_matches?(payload, :sign_in_nonce)
      return true unless respond_to?(:verifiable_subject)

      payload["subject"] == verifiable_subject &&
        payload["version"].is_a?(Integer) &&
        payload["version"] == verifiable_subject_version
    end

    def magic_linkable_config
      Vouch.configuration.magic_linkable
    end
  end
end
