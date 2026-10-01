# frozen_string_literal: true

require "active_support/security_utils"
require "securerandom"
require_relative "../persistence"

# Signed-token verification for clickable links (invitations, magic links,
# unsubscribe URLs, etc.). Builds on Verifiable.
#
# Tokens are produced by `Rails.application.message_verifier(purpose)` and
# carry the record id plus a per-row nonce. Consuming a token verifies the
# row AND rotates the nonce in the same UPDATE, which:
#   - enforces single-use (a replay of the old token finds a new nonce)
#   - invalidates any sibling tokens issued before the consume
#   - lets you force-rotate to revoke in-flight tokens out-of-band
#
# Required columns:
#   - verified_at         (datetime, nullable)
#   - confirmation_nonce  (string,   nullable; unique index recommended)
#
# Per-model tunables (class_attribute, override per-class):
#   - token_validity      (default: 1.day)
#   - token_purpose       (default: nil — falls back to model_name.singular)
#
# Public surface:
#   - #confirmation_token             => signed String
#   - #rotate_confirmation_nonce!     => invalidates outstanding tokens
#   - .consume_token(token)           => Result(record) on success
#   - .token_verifier                 => the MessageVerifier instance
#
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

      def rotate_confirmation_nonce!
        Vouch::Persistence.transaction(self) do
          Vouch::Persistence.update!(self, confirmation_nonce: SecureRandom.hex(16))
        end
      end

      class_methods do
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
