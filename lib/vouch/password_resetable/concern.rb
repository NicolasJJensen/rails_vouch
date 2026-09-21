require_relative "../persistence"

# Hashed, time-limited password reset tokens.
#
# Generates a one-time token and stores only its SHA-256 digest in the database.
# Lookups hash the incoming token and compare digests using constant-time
# comparison. The raw token is delivered to the user once via email and never
# stored.
#
# Required columns on the account model:
#   - password_reset_token_digest  (string, indexed)
#   - password_reset_sent_at       (datetime)
#
# Token expiry is read from `auth_config(:password_resetable, :expiry)`.
#
module Vouch
  module PasswordResetable
    module Concern
      extend ActiveSupport::Concern

      included do
        before_update :revoke_reset_on_password_change
      end

      # Generate a new reset token. Returns Result.ok(raw token); persists only
      # the digest and timestamp. Caller is responsible for delivering the
      # raw token to the user.
      def generate_password_reset_token!
        raw = SecureRandom.urlsafe_base64(32)
        Vouch::Persistence.transaction(self) do
          Vouch::Persistence.update!(self,
            password_reset_token_digest: self.class.digest_password_reset_token(raw),
            password_reset_sent_at: Time.current
          )
        end
        Vouch::Result.ok(raw)
      end

      # True when the stored reset token has expired according to the
      # configured `:expiry` window.
      def password_reset_expired?
        return true unless password_reset_sent_at

        expiry = auth_config(:password_resetable, :expiry)
        password_reset_sent_at + expiry < Time.current
      end

      # Clear the digest and timestamp. Call inside the transaction that
      # writes the new password.
      def clear_password_reset!
        Vouch::Persistence.transaction(self) do
          Vouch::Persistence.update!(self, password_reset_token_digest: nil, password_reset_sent_at: nil)
        end
      end

      # Atomically consume a gem-issued token and update the password.  This
      # deliberately has a gem-specific name so Rails' has_secure_password
      # token API cannot override it based on declaration order.
      def reset_password_with_token!(token, **password_attrs)
        unsupported = password_attrs.keys - %i[password password_confirmation]
        if unsupported.any?
          raise ArgumentError, "unsupported reset attributes: #{unsupported.join(', ')}"
        end

        return Vouch::Result.invalid unless token.is_a?(String) && token.present?
        return Vouch::Result.invalid if password_attrs[:password].blank?

        if password_attrs.key?(:password) && !password_attrs.key?(:password_confirmation)
          password_attrs[:password_confirmation] = password_attrs[:password]
        end

        Vouch::Persistence.transaction(self) do
          lock!
          next Vouch::Result.invalid unless password_reset_token_matches?(token)

          Vouch::Persistence.update!(self, password_attrs.merge(
            password_reset_token_digest: nil,
            password_reset_sent_at: nil
          ))
          Vouch::Result.ok(self)
        end
      rescue ActiveRecord::RecordInvalid
        Vouch::Result.invalid
      rescue Vouch::Persistence::Cancelled
        Vouch::Result.cancelled
      end

      class_methods do
        # Constant-time digest lookup. Hashes the incoming token, queries by
        # digest, and rejects expired records.
        def find_by_auth_password_reset_token(token)
          return nil unless token.is_a?(String) && token.present?

          digest = digest_password_reset_token(token)
          record = find_by(password_reset_token_digest: digest)
          return nil unless record
          return nil if record.password_reset_expired?

          # Constant-time verification against the canonical digest, defending
          # against any timing variance in the database lookup.
          return nil unless ActiveSupport::SecurityUtils.fixed_length_secure_compare(
            digest, record.password_reset_token_digest
          )

          record
        end

        def digest_password_reset_token(raw)
          Digest::SHA256.hexdigest(raw)
        end
      end

      private

      def revoke_reset_on_password_change
        return unless will_save_change_to_password_digest?
        self.password_reset_token_digest = nil
        self.password_reset_sent_at = nil
      end

      def password_reset_token_matches?(token)
        return false if password_reset_expired?
        digest = self.class.digest_password_reset_token(token)
        stored = password_reset_token_digest.to_s
        return false if stored.empty? || stored.bytesize != digest.bytesize

        ActiveSupport::SecurityUtils.fixed_length_secure_compare(digest, stored)
      end
    end
  end
end
