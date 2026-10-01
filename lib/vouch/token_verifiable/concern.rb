# frozen_string_literal: true

require "active_support/security_utils"
require "securerandom"
require_relative "../persistence"

# Signed confirmation links for saved records. Nonce rotation provides
# explicit revocation; confirmation also clears any outstanding code challenge.
module Vouch
  module TokenVerifiable
    module Concern
      extend ActiveSupport::Concern
      include Vouch::VerificationSubject

      included do
        class_attribute :token_validity, default: 1.day
        class_attribute :token_purpose,  default: nil

        scope :verified,   -> { where.not(verified_at: nil) }
        scope :unverified, -> { where(verified_at: nil) }

        before_create :assign_confirmation_nonce
      end

      def verified?
        verified_at.present?
      end

      def confirmation_token
        raise ArgumentError, "cannot generate a confirmation token for an unpersisted record" unless persisted?

        rotate_confirmation_nonce! if confirmation_nonce.blank?

        self.class.token_verifier.generate(
          { id: Vouch::RecordKey.value(self), nonce: confirmation_nonce, subject: confirmation_subject },
          expires_in: token_validity,
          purpose:    self.class.token_purpose_key
        )
      end

      def confirmation_subject
        verifiable_subject
      end

      def rotate_confirmation_nonce
        Vouch::Persistence.transaction(self) do
          lock!
          Vouch::Persistence.update!(self, confirmation_nonce: SecureRandom.hex(16))
        end
        Vouch::Result.ok(self)
      rescue Vouch::Persistence::Cancelled, ActiveRecord::RecordNotSaved => error
        Vouch::Result.cancelled(record: self, error: error)
      rescue ActiveRecord::RecordInvalid => error
        Vouch::Result.invalid(record: self, error: error)
      end

      def rotate_confirmation_nonce!
        result = rotate_confirmation_nonce
        raise Vouch::OperationFailed, result unless result.ok?
        result
      end

      class_methods do
        def consume_token!(token)
          result = consume_token(token)
          raise Vouch::OperationFailed, result unless result.ok?
          result
        end

        def consume_token(token)
          return Vouch::Result.invalid unless token.is_a?(String)

          payload = token_verifier.verify(token, purpose: token_purpose_key)
          return Vouch::Result.invalid unless payload.is_a?(Hash)

          expected = (payload[:nonce] || payload["nonce"]).to_s
          return Vouch::Result.invalid if expected.empty?

          record = begin
            Vouch::RecordKey.find(self, payload[:id] || payload["id"])
          rescue ActiveRecord::RecordNotFound, ArgumentError
            return Vouch::Result.invalid
          end
          Vouch::Persistence.transaction(record) do
            record = Vouch::RecordKey.find(lock, payload[:id] || payload["id"])
            next Vouch::Result.invalid unless record.confirmation_subject == (payload[:subject] || payload["subject"])
            next Vouch::Result.already_verified(record) if record.verified?

            actual = record.confirmation_nonce.to_s
            next Vouch::Result.invalid if actual.empty?
            next Vouch::Result.invalid unless ActiveSupport::SecurityUtils.secure_compare(expected, actual)

            attrs = { verified_at: Time.current, confirmation_nonce: SecureRandom.hex(16) }
            attrs[:verification_nonce] = nil if record.has_attribute?(:verification_nonce)
            Vouch::Persistence.update!(record, attrs)
            Vouch::Result.ok(record)
          end
        rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
          Vouch::Result.invalid
        rescue Vouch::Persistence::Cancelled => error
          Vouch::Result.cancelled(record: error.record, error: error)
        end

        def token_verifier
          Rails.application.message_verifier(token_purpose_key)
        end

        def token_purpose_key
          (token_purpose || "vouch/#{model_name.singular}_confirmation").to_sym
        end
      end

      private

      def assign_confirmation_nonce
        self.confirmation_nonce ||= SecureRandom.hex(16)
      end
    end
  end
end
