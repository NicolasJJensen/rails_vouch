module Vouch
  class AuthenticationPolicy
    def allowed?(account, method:, provider:, controller:)
      !account.locked?
    end

    def two_factor_required?(account, method:, provider:, controller:)
      unless account.class.auth_feature_enabled?(:two_factorable)
        if controller.respond_to?(:auth_mapping, true) &&
            controller.send(:auth_mapping).two_factor_association_configured?
          raise Vouch::ConfigurationError, <<~MSG.squish
            An explicit 2FA credential association is configured for this scope,
            but #{account.class.name} does not enable :two_factorable via authenticates_with.
            Add the marker or provide a custom authentication policy.
          MSG
        end
        return false
      end
      return false if method.to_s == 'oauth' && Vouch.configuration.oauth_mfa_providers.map(&:to_s).include?(provider.to_s)

      account.respond_to?(:two_factor_enabled?) && account.two_factor_enabled?
    end

    # Return nil when a membership accepts ordinary account MFA. Applications
    # may return { credential_types:, credential_methods:, max_age:,
    # allow_recovery_codes: } for a
    # tenant-specific second challenge.
    def membership_mfa_requirements(_account, identity:, tenant:, controller:)
      nil
    end
  end
end
