# frozen_string_literal: true

module Vouch
  module VerificationState
    def serialize_verification_state
      raise ArgumentError, "Verification state can only export an unsaved record" unless new_record?

      @verification_state_expires_at ||= Time.current.to_f + Vouch.configuration.pending_authentication_ttl.to_f
      exported_attributes = attributes.except(
        "password", "password_confirmation", "password_digest", "code", "otp", "otp_code",
        "sign_in_nonce", "two_factor_nonce", "recovery_codes"
      ).reject { |name, _| name.start_with?("password_") }
      exported_attributes["two_factor_enabled_at"] = nil if has_attribute?(:two_factor_enabled_at)
      unless @verification_verified_subject == verifiable_subject && @verification_verified_version == send(:verifiable_subject_version)
        exported_attributes = exported_attributes.merge("verified_at" => nil)
      end
      payload = {
        "model" => self.class.name,
        "attributes" => exported_attributes,
        "subject" => verifiable_subject,
        "challenge_token" => challenge_token,
        "expires_at" => @verification_state_expires_at
      }
      verification_state_encryptor.encrypt_and_sign(payload, purpose: "verification-state")
    end

    def restore_verification_state(serialized)
      raise ArgumentError, "Verification state can only restore an unsaved record" unless new_record?
      return Vouch::Result.invalid unless serialized.is_a?(String)

      payload = verification_state_encryptor.decrypt_and_verify(serialized, purpose: "verification-state")
      return Vouch::Result.invalid unless payload.is_a?(Hash) && payload["model"] == self.class.name
      expiry = payload["expires_at"]
      return Vouch::Result.invalid unless expiry.is_a?(Numeric) && expiry > Time.current.to_f

      candidate = self.class.new(payload.fetch("attributes"))
      return Vouch::Result.invalid unless candidate.verifiable_subject == payload["subject"]

      @restoring_verification_state = true
      assign_attributes(payload.fetch("attributes"))
      if verified?
        @verification_verified_subject = verifiable_subject
        @verification_verified_version = send(:verifiable_subject_version)
      end

      self.challenge_token = payload["challenge_token"]
      @verification_state_expires_at = expiry
      Vouch::Result.ok(self)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      Vouch::Result.invalid
    ensure
      @restoring_verification_state = false
    end

    def restore_verification_state!(serialized)
      result = restore_verification_state(serialized)
      raise Vouch::OperationFailed, result unless result.ok?

      result
    end

    private

    def verification_state_encryptor
      key = Rails.application.key_generator.generate_key("vouch/verification-state", 32)
      ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm", serializer: JSON)
    end
  end
end
