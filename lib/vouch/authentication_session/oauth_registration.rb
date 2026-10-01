# frozen_string_literal: true

module Vouch
  class AuthenticationSession
    module OAuthRegistration
      def consume_oauth_initiation(auth_hash)
        nonce = controller.request.env.fetch("omniauth.params", {})[Vouch::OAuthInitiation::REQUEST_PARAM]
        contexts = session[Vouch::OAuthInitiation.contexts_key(scope)]
        context = contexts.delete(nonce) if contexts.is_a?(Hash) && nonce.is_a?(String)
        return unless context.is_a?(Hash) && context["issued_at"].is_a?(Numeric)

        age = Time.current.to_f - context["issued_at"]
        return unless age >= 0 && age < Vouch.configuration.pending_authentication_ttl.to_f
        return unless context["scope"] == scope.to_s && context["provider"] == auth_hash.provider.to_s

        context
      end

      def oauth_initiation_matches_account?(context, account)
        return false unless context && account
        return false unless context["account_scope"] == controller.send(:auth_mapping).evidence_scope_name.to_s
        return false unless Vouch::RecordKey.same?(context["account_id"], Vouch::RecordKey.serialize(account), model: account.class)
        return false unless context["fingerprint"] == Vouch::PendingAuthentication.fingerprint(account)

        ActiveSupport::SecurityUtils.secure_compare(context["context_id"].to_s, context_id)
      end

      def begin_oauth_registration!(auth_hash)
        session[key(:oauth_registration)] = {
          'oauth' => controller.send(:serialize_oauth, auth_hash),
          'issued_at' => Time.current.to_f
        }
      end

      def load_oauth_registration
        context = session[key(:oauth_registration)]
        unless context.is_a?(Hash) && context['issued_at'].is_a?(Numeric) &&
            Time.current.to_f - context['issued_at'] >= 0 &&
            Time.current.to_f - context['issued_at'] < Vouch.configuration.pending_authentication_ttl.to_f
          clear_oauth_registration
          return nil
        end

        oauth = controller.send(:parse_oauth, context['oauth'])
        return oauth if oauth.provider.present? && oauth.uid.present?

        clear_oauth_registration
        nil
      rescue StandardError
        clear_oauth_registration
        nil
      end

      def oauth_registration_present?
        session.key?(key(:oauth_registration))
      end

      def oauth_initiation_return_to
        session[Vouch::OAuthInitiation.return_to_key(scope)]
      end

      def clear_oauth_initiation_return_to
        session.delete(Vouch::OAuthInitiation.return_to_key(scope))
      end

      def clear_oauth_registration
        session.delete(key(:oauth_registration))
      end
    end
  end
end
