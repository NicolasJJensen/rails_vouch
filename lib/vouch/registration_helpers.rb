module Vouch
  module RegistrationHelpers
    private

    # Builds and saves the records that make up a registration. Host overrides
    # build unsaved records so Vouch can persist every record in one
    # transaction.
    def create_registration_identity!(account)
      tenant = build_tenant(account)
      Vouch::Persistence.save!(tenant) if tenant && !tenant.persisted?

      identity = build_identity(account, tenant: tenant)
      Vouch::Persistence.save!(identity) unless identity.equal?(account) || identity.persisted?
      identity
    end

    # Return an unsaved tenant for a split-model registration. Override this
    # in the generated application registration controller.
    def build_tenant(account)
      return nil unless registration_mapping.tenant?

      raise NotImplementedError, <<~MSG.squish
        Define #build_tenant(account) in the host registration controller.
        Return an unsaved #{registration_mapping.tenant_class_name}.
      MSG
    end

    # Return an unsaved identity. For a single-model scope the account itself
    # is the identity. The returned record is persisted by Vouch.
    def build_identity(account, tenant:)
      mapping = registration_mapping
      return account unless mapping.split_model?

      attributes = {mapping.account_association => account}
      if tenant
        tenant.public_send(mapping.tenant_identity_association.name).build(attributes)
      else
        mapping.identity_class.new(attributes)
      end
    end

    def registration_mapping
      destination = session[Vouch::Session.key_for(auth_scope_name, :destination_scope)]
      return auth_mapping unless destination && Vouch.registered_scope?(destination)

      mapping = Vouch.mapping_for(destination)
      mapping.parent_scope_name == auth_scope_name ? mapping : auth_mapping
    end
  end
end
