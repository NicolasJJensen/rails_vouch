# frozen_string_literal: true

require_relative "../persistence"

module Vouch
  module PasswordResetable
    module Concern
      extend ActiveSupport::Concern

      included do
        before_update :revoke_reset_on_security_change
      end

      def generate_password_reset_token
        token = nil
        Vouch::Persistence.transaction(self) do
          lock!
          attributes = password_reset_revocation_attributes
          if self.class.password_reset_strategy == :signed
            attributes[:password_reset_nonce] = SecureRandom.urlsafe_base64(32)
            Vouch::Persistence.update!(self, attributes)
            token = self.class.password_reset_verifier.generate(
              { "key" => Vouch::RecordKey.serialize(self),
                "nonce" => password_reset_nonce, "password" => password_reset_fingerprint },
              expires_in: auth_config(:password_resetable, :expiry), purpose: "password_reset"
            )
          else
            token = SecureRandom.urlsafe_base64(32)
            attributes.merge!(password_reset_token_digest: self.class.digest_password_reset_token(token),
              password_reset_sent_at: Time.current)
            Vouch::Persistence.update!(self, attributes)
          end
        end
        Vouch::Result.ok(token, record: self)
      rescue ActiveRecord::RecordInvalid => error
        Vouch::Result.new(:invalid, nil, record: self, error: error)
      rescue ActiveRecord::RecordNotSaved, Vouch::Persistence::Cancelled => error
        Vouch::Result.new(:cancelled, nil, record: self, error: error)
      end

      def generate_password_reset_token!
        result = generate_password_reset_token
        raise Vouch::OperationFailed, result unless result.ok?
        result
      end

      def clear_password_reset
        Vouch::Persistence.transaction(self) do
          lock!
          Vouch::Persistence.update!(self, password_reset_revocation_attributes)
        end
        Vouch::Result.ok(self)
      rescue ActiveRecord::RecordInvalid => error
        Vouch::Result.new(:invalid, nil, record: self, error: error)
      rescue ActiveRecord::RecordNotSaved, Vouch::Persistence::Cancelled => error
        Vouch::Result.new(:cancelled, nil, record: self, error: error)
      end

      def clear_password_reset!
        result = clear_password_reset
        raise Vouch::OperationFailed, result unless result.ok?
        result
      end

      def reset_password_with_token(token, **password_attrs)
        unsupported = password_attrs.keys - %i[password password_confirmation]
        raise ArgumentError, "unsupported reset attributes: #{unsupported.join(', ')}" if unsupported.any?
        return Vouch::Result.new(:invalid, nil, record: self) unless token.is_a?(String) && token.present?
        if password_attrs[:password].blank?
          errors.add(:password, :blank)
          return Vouch::Result.new(:invalid, nil, record: self)
        end
        password_attrs[:password_confirmation] = password_attrs[:password] unless password_attrs.key?(:password_confirmation)

        Vouch::Persistence.transaction(self) do
          lock!
          unless password_reset_token_matches?(token)
            errors.add(:base, I18n.t("vouch.passwords.invalid_token"))
            next Vouch::Result.new(:invalid, nil, record: self)
          end
          Vouch::Persistence.update!(self, password_attrs.merge(password_reset_revocation_attributes))
          Vouch::Result.ok(self)
        end
      rescue ActiveRecord::RecordInvalid => error
        Vouch::Result.new(:invalid, nil, record: self, error: error)
      rescue ActiveRecord::RecordNotSaved, Vouch::Persistence::Cancelled => error
        Vouch::Result.new(:cancelled, nil, record: self, error: error)
      end

      def reset_password_with_token!(token, **password_attrs)
        result = reset_password_with_token(token, **password_attrs)
        raise Vouch::OperationFailed, result unless result.ok?
        result
      end

      class_methods do
        def password_reset_strategy
          strategy = auth_config(:password_resetable, :token_strategy).to_sym
          return strategy if %i[signed opaque].include?(strategy)
          raise Vouch::ConfigurationError, "Unknown password reset token strategy: #{strategy.inspect}"
        end

        def password_reset_verifier
          Rails.application.message_verifier("vouch/password-reset/#{name}")
        end

        def find_by_auth_password_reset_token(token)
          return unless token.is_a?(String) && token.present?
          record = if password_reset_strategy == :signed
            payload = password_reset_verifier.verified(token, purpose: "password_reset")
            key = payload["key"] if payload.is_a?(Hash)
            return unless key.is_a?(String)
            begin
              Vouch::RecordKey.find(all, key)
            rescue ActiveRecord::RecordNotFound
              nil
            end
          else
            find_by(password_reset_token_digest: digest_password_reset_token(token))
          end
          record if record && record.send(:password_reset_token_matches?, token)
        end

        def digest_password_reset_token(raw)
          Digest::SHA256.hexdigest(raw)
        end
      end

      private

      def password_reset_fingerprint
        Digest::SHA256.hexdigest(password_digest.to_s)
      end

      def password_reset_revocation_attributes
        %i[password_reset_nonce password_reset_token_digest password_reset_sent_at]
          .select { |attribute| has_attribute?(attribute) }.to_h { |attribute| [attribute, nil] }
      end

      def revoke_reset_on_security_change
        changed = will_save_change_to_password_digest? ||
          (has_attribute?(:email_address) && will_save_change_to_attribute?(:email_address))
        return unless changed

        password_reset_revocation_attributes.each_key do |attribute|
          self[attribute] = nil
          attribute_will_change!(attribute)
        end
      end

      def password_reset_token_matches?(token)
        return false unless token.is_a?(String) && token.present?
        if self.class.password_reset_strategy == :signed
          payload = self.class.password_reset_verifier.verified(token, purpose: "password_reset")
          return false unless payload.is_a?(Hash) && password_reset_nonce.present?
          return false unless payload["key"].is_a?(String)
          key = Vouch::RecordKey.from_param(self.class, payload["key"])
          key && Vouch::RecordKey.same?(self, key, model: self.class) &&
            ActiveSupport::SecurityUtils.secure_compare(payload["nonce"].to_s, password_reset_nonce) &&
            ActiveSupport::SecurityUtils.secure_compare(payload["password"].to_s, password_reset_fingerprint)
        else
          return false if password_reset_sent_at.nil? ||
            password_reset_sent_at + auth_config(:password_resetable, :expiry) <= Time.current ||
            password_reset_token_digest.blank?
          ActiveSupport::SecurityUtils.secure_compare(self.class.digest_password_reset_token(token), password_reset_token_digest)
        end
      end
    end
  end
end
