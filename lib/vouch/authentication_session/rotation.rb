# frozen_string_literal: true

module Vouch
  class AuthenticationSession
    module Rotation
      def reset_with_preserved_keys
        keys = PRESERVED_KEYS + scoped_keys + Vouch.configuration.preserved_session_keys.map(&:to_s)
        preserved = keys.uniq.each_with_object({}) do |key, values|
          values[key] = rails_session[key] if rails_session.key?(key)
        end
        scopes = Vouch.configuration.preserved_auth_scopes.map(&:to_sym) - [scope, account_scope]
        identities = scopes.to_h { |other_scope| [other_scope, warden.user(other_scope)] }
        controller.reset_session
        preserved.each { |key, value| rails_session[key] = value }
        identities.each { |other_scope, identity| warden.set_user(identity, scope: other_scope, store: true) if identity }
      end
    end
  end
end
