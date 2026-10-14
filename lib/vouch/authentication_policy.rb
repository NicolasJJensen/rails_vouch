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

      account.respond_to?(:two_factor_enabled?) && account.two_factor_enabled?
    end

    def sign_in_approval_required?(account, method:, provider:, controller:)
      false
    end

    def sign_in_approval_credential(account, method:, provider:, controller:)
      nil
    end

    def sign_in_approval_satisfied?(account, credential:, evidence:, method:, provider:, controller:)
      evidence["method"] == "two_factor" &&
        evidence["credential_type"] == credential.class.name &&
        evidence["credential_id"] == Vouch::RecordKey.serialize(credential)
    end
  end
end
