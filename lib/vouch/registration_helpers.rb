module Vouch
  module RegistrationHelpers
    private

    def build_registration(account)
      mapping = auth_mapping

      if mapping.tenant?
        tenant = build_tenant_for_registration(account)
        build_identity_for_registration(account, tenant: tenant)
      elsif mapping.split_model?
        build_identity_for_registration(account, tenant: nil)
      else
        account
      end
    end

    def build_tenant_for_registration(account)
      Vouch::Persistence.create!(
        auth_mapping.tenant_class,
        registration_tenant_attributes(account)
      )
    end

    def build_identity_for_registration(account, tenant:)
      attrs = registration_identity_attributes(account, tenant: tenant)
      if tenant
        assoc = auth_mapping.tenant_identity_association
        Vouch::Persistence.create!(tenant.send(assoc.name), attrs)
      else
        Vouch::Persistence.create!(auth_mapping.identity_class, attrs)
      end
    end

    def registration_identity_attributes(account, tenant:)
      { auth_mapping.account_association => account }
    end

    def registration_tenant_attributes(account)
      raise NotImplementedError, <<~MSG.squish
        The host controller must define #registration_tenant_attributes(account).
        Return a hash of attributes for creating the tenant.

        Example:
          def registration_tenant_attributes(account)
            { name: "\#{account.email_address}'s Workspace" }
          end
      MSG
    end
  end
end
