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
      unless trusted_verification?
        exported_attributes = exported_attributes.merge("verified_at" => nil)
      end
      payload = {
        "model" => self.class.name,
        "attributes" => verification_serializable_value(exported_attributes),
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
        @verification_verified_at = verified_at
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

    def apply_verification_to(record)
      return Vouch::Result.invalid unless new_record? && record.persisted? && record.class == self.class
      return Vouch::Result.invalid unless trusted_verification?
      @verification_state_expires_at ||= verified_at.to_f + Vouch.configuration.pending_authentication_ttl.to_f
      return Vouch::Result.invalid unless @verification_state_expires_at > Time.current.to_f

      Vouch::Persistence.transaction(record) do
        record.lock!
        if record.verified? && record.verifiable_subject == verifiable_subject
          next Vouch::Result.already_verified(record)
        end

        canonical_verifiable_subject_attributes.each do |attribute|
          record.public_send("#{attribute}=", public_send(attribute))
        end
        %i[verification_nonce confirmation_nonce sign_in_nonce two_factor_nonce].each do |attribute|
          record[attribute] = nil if record.has_attribute?(attribute)
        end
        record.verified_at = verified_at
        record.verification_attempts = 0
        record.verification_locked_at = nil
        record.instance_variable_set(:@applying_trusted_verification, true)
        begin
          Vouch::Persistence.save!(record)
          unless record.verified? && record.verifiable_subject == verifiable_subject
            record.errors.add(:base, "The verified subject changed during replacement")
            raise ActiveRecord::Rollback
          end
        ensure
          record.instance_variable_set(:@applying_trusted_verification, false)
        end
        Vouch::Result.ok(record)
      end
    rescue Vouch::Persistence::Cancelled, ActiveRecord::RecordNotSaved => error
      Vouch::Result.cancelled(record: record, error: error)
    rescue ActiveRecord::RecordInvalid => error
      Vouch::Result.invalid(record: record, error: error)
    end

    def apply_verification_to!(record)
      result = apply_verification_to(record)
      raise Vouch::OperationFailed, result unless result.ok?
      result
    end

    private

    def trusted_verification?
      verified? && @verification_verified_subject == verifiable_subject &&
        @verification_verified_version == send(:verifiable_subject_version) &&
        @verification_verified_at == verified_at
    end

    def verification_state_encryptor
      key = Rails.application.key_generator.generate_key("vouch/verification-state", 32)
      ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm", serializer: JSON)
    end
  end
end
