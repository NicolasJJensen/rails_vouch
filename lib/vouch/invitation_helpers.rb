module Vouch
  module InvitationHelpers
    private

    def assign_tenant_to_invitee(invitee, inviter)
      return unless auth_mapping.tenant?

      assoc = auth_mapping.identity_tenant_association
      unless assoc
        raise Vouch::ConfigurationError, <<~MSG.squish
          Cannot copy tenant from inviter to invitee: scope :#{auth_scope_name}
          has tenant: "#{auth_mapping.tenant_class_name}" but no belongs_to from
          #{auth_mapping.identity_class_name} to that tenant model.
        MSG
      end

      invitee.send("#{assoc.name}=", inviter.send(assoc.name))
    end

    def pending_invited_identity
      authentication_session.load_invitation
    end

    def valid_pending_invitation?(identity)
      payload = session[invited_user_session_key]
      return false unless payload.is_a?(Hash) && payload['token'].present?
      identity.invitation_token.present? && !identity.invitation_expired? &&
        ActiveSupport::SecurityUtils.secure_compare(identity.invitation_token, payload['token'])
    end

    def invitation_requires_registration?(invitation)
      invitation.invitation_registration_required? && invitation_account_for(invitation).registration_required?
    end

    def accept_pending_invitation(account, publish: true)
      invitation = pending_invited_identity
      return nil unless invitation && invitation_account_for(invitation) == account
      return nil if invitation_requires_registration?(invitation)
      accepted = account.with_lock do
        invitation.with_lock do
          # The invitation can be reassigned or require registration while it waits for this lock.
          next false unless invitation_account_for(invitation) == account
          next false if invitation_requires_registration?(invitation)
          next false unless valid_pending_invitation?(invitation)
          invitation.accept_invitation!
          true
        end
      end
      return nil unless accepted
      publish_invitation_acceptance(account, invitation) if publish
      invitation
    end

    def publish_invitation_acceptance(account, invitation)
      authentication_session.clear_invitation
      run_hooks(:invitation_acceptance, invitation) { |env| env.add(account) }
    end

    def build_invited_account(identifier)
      build_invited_identity(identifier)
    end

    def invitation_account_for(invitation)
      invitation_mapping_for(invitation).account_for(invitation)
    end

    def invitation_mapping_for(invitation)
      payload = session[invited_user_session_key]
      scope = payload.is_a?(Hash) && payload["scope"]
      scope ? Vouch.mapping_for(scope) : auth_mapping
    end

    def build_invited_identity(identifier)
      account_class_name = auth_mapping.account_class_name
      raise NotImplementedError, <<~MSG.squish
        Define #build_invited_identity(identifier) in the host controller.
        Return an existing #{account_class_name} or create one with a random
        password. Normalize the identifier using the account model's rules.
      MSG
    end
  end
end
