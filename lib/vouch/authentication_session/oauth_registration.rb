# frozen_string_literal: true

module Vouch
  class AuthenticationSession
    module OAuthRegistration
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

      def clear_oauth_registration
        session.delete(key(:oauth_registration))
      end
    end
  end
end
