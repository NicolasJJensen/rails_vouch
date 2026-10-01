module Vouch
  module RegistrationHelpers
    private

    def invitation_registration?
      invitation = pending_invited_identity
      invitation && invitation_requires_registration?(invitation) ? true : false
    end

    def persist_oauth_registration!(account, oauth_hashes)
      invitation = pending_invited_identity
      if session[invited_user_session_key].present? && (!invitation || !invitation_requires_registration?(invitation))
        raise Vouch::Invitable::InvitationExpiredError
      end
      if invitation
        lock_registration_record!(account)
        invitation.lock! unless invitation.equal?(account)
        unless valid_pending_invitation?(invitation) && invitation_requires_registration?(invitation)
          raise Vouch::Invitable::InvitationExpiredError
        end
      end
      persist_registration_record!(account)
      oauth_hashes.each do |oauth|
        Vouch::Persistence.create!(
          account.public_send(auth_mapping.oauth_identity_association.name),
          auth_mapping.oauth_identity_class.oauth_attributes(oauth)
            .merge(authentication_session.oauth_registration_identity_attributes(oauth))
        )
      end
      validate_registration_authentication!(account, oauth: oauth_hashes.first)
      if invitation
        account.complete_registration!
        accept_pending_invitation_in_transaction(account, invitation)
        invitation
      else
        create_registration_identity!(account)
      end
    end

    def validate_submitted_registration_password!(account, attributes)
      return unless attributes.key?(:password) && attributes[:password].blank?

      account.errors.add(:password, :blank)
      raise ActiveRecord::RecordInvalid.new(account)
    end

    def validate_registration_authentication!(account, oauth: nil)
      return if registration_authentication_available?(account, oauth: oauth)

      account.errors.add(:base, I18n.t("vouch.registrations.sign_in_method_required"))
      raise ActiveRecord::RecordInvalid.new(account)
    end

    def registration_authentication_available?(account, oauth: nil)
      return true if account.password_digest.present?
      return false unless oauth && oauth.provider.present? && oauth.uid.present?

      account.public_send(auth_mapping.oauth_identity_association.name)
        .exists?(provider: oauth.provider, uid: oauth.uid)
    end

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
