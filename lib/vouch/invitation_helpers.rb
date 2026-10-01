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
      owner = invitation_account_for(identity)
      return false unless Vouch::RecordKey.same?(payload['account_id'], Vouch::RecordKey.serialize(owner), model: owner.class)
      identity.invitation_token.present? && !identity.invitation_expired? &&
        ActiveSupport::SecurityUtils.secure_compare(identity.invitation_token, payload['token'])
    end

    def invitation_requires_registration?(invitation)
      invitation_account_for(invitation).registration_required?
    end

    def run_authentication_hooks_with_invitation(kind, account, *args, **kwargs, &operation)
      invitation = pending_invited_identity unless @wrapping_invitation_acceptance
      unless invitation && (invitation_account_for(invitation) == account || invitation_link_allowed?(invitation, account))
        return run_authentication_hooks(kind, account, *args, **kwargs, &operation)
      end

      previous = @completed_invitation_acceptance
      wrapped = true
      @wrapping_invitation_acceptance = true
      @completed_invitation_acceptance = nil
      run_authentication_hooks(:invitation_acceptance, invitation, account) do |env|
        completed = run_authentication_hooks(kind, account, *args, **kwargs, &operation)
        env.abort! unless completed && @completed_invitation_acceptance
        true
      end
    ensure
      if wrapped
        @wrapping_invitation_acceptance = false
        @completed_invitation_acceptance = previous
      end
    end

    def accept_pending_invitation(account, publish: true, transactional: false)
      invitation = pending_invited_identity
      return nil unless invitation && invitation_acceptance_allowed?(invitation, account)

      return accept_pending_invitation_in_transaction(account, invitation) if transactional

      accepted = run_authentication_hooks(:invitation_acceptance, invitation, account) do |env|
        committed = begin
          run_commit_hooks(:invitation_acceptance, invitation, account) do
            consume_pending_invitation!(account, invitation)
          end
        rescue Vouch::Persistence::Cancelled
          false
        end
        env.abort! unless committed
        if committed && publish
          publish_invitation_acceptance
        end
        committed
      end
      return nil unless accepted
      invitation
    end

    def accept_pending_invitation_in_transaction(account, invitation)
      accepted = account.with_lock do
        invitation.with_lock do
          # The invitation can be reassigned or require registration while it waits for this lock.
          locked_invitation = invitation.class.find(invitation.id)
          next false unless invitation_acceptance_allowed?(locked_invitation, account)
          next false unless valid_pending_invitation?(locked_invitation)

          core_ran = false
          result = run_hooks(:invitation_acceptance, locked_invitation, account) do
            core_ran = true
            perform_pending_invitation_acceptance(account, locked_invitation)
            true
          end
          raise Vouch::Persistence::Cancelled unless core_ran && result

          true
        end
      end
      accepted || raise(Vouch::Persistence::Cancelled)
    end

    def perform_pending_invitation_acceptance(account, invitation)
      # The caller holds both records' locks. Recheck the account relation and
      # token immediately before consuming the invitation.
      invitation.reload
      raise Vouch::Persistence::Cancelled unless invitation_acceptance_allowed?(invitation, account)
      raise Vouch::Persistence::Cancelled unless valid_pending_invitation?(invitation)

      if invitation_account_for(invitation) != account
        original_account = invitation_account_for(invitation)
        original_account.lock!
        raise Vouch::Persistence::Cancelled unless invitation_link_allowed?(invitation, account)
        mapping = invitation_mapping_for(invitation)
        existing = mapping.identities_for(account)
        if mapping.tenant?
          association = mapping.identity_tenant_association.name
          existing = existing.where(association => invitation.public_send(association))
        end
        raise Vouch::Persistence::Cancelled if existing.exists?
        Vouch::Persistence.update!(invitation, mapping.account_association => account)
      end
      raise Vouch::Persistence::Cancelled unless invitation.accept_invitation.ok?
      @completed_invitation_acceptance = invitation
    end

    def consume_pending_invitation!(account, invitation)
      account.with_lock do
        invitation.with_lock do
          locked_invitation = invitation.class.find(invitation.id)
          perform_pending_invitation_acceptance(account, locked_invitation)
        end
      end
    end

    def publish_invitation_acceptance
      authentication_session.clear_invitation
    end

    def invitation_account_for(invitation)
      mapping = invitation_mapping_for(invitation)
      if mapping.split_model?
        association = invitation.association(mapping.account_association)
        association.reset if association.loaded?
      end
      mapping.account_for(invitation)
    end

    def invitation_mapping_for(invitation)
      payload = session[invited_user_session_key]
      scope = payload.is_a?(Hash) && payload["scope"]
      scope ? Vouch.mapping_for(scope) : auth_mapping
    end

    def invitation_link_allowed?(invitation, account)
      payload = session[invited_user_session_key]
      return false unless payload.is_a?(Hash) && %w[current existing].include?(payload["choice"])
      return false unless invitation_mapping_for(invitation).split_model?
      return false unless valid_pending_invitation?(invitation)
      return false if account.registration_required?

      invitation_account_for(invitation).registration_required?
    end

    def invitation_acceptance_allowed?(invitation, account)
      owner = invitation_account_for(invitation)
      (owner == account && !owner.registration_required?) || invitation_link_allowed?(invitation, account)
    end

    def build_invited_account(identifier)
      account_class_name = auth_mapping.account_class_name
      raise NotImplementedError, <<~MSG.squish
        Define #build_invited_account(identifier) in the host controller.
        Return an existing #{account_class_name} or build an unsaved one.
        Normalize the identifier using the account model's rules; do not persist
        or deliver anything while preparing the invitation.
      MSG
    end
  end
end
