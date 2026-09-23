class Vouch::InvitationsController < ::ApplicationController
  include Vouch::Authentication
  allow_unauthenticated_access only: :accept
  before_action :authorize_invitation!, only: :create

  def new; end

  def create
    identifier = params[:email_address] || params[:identifier]
    transaction_record = auth_mapping.identity_class.new
    invitee = Vouch::Persistence.transaction(transaction_record) do
      account = build_invited_identity(identifier)
      account.lock!
      requires_registration = account.registration_required?
      if auth_mapping.split_model?
        result = auth_mapping.identity_class.invite!(invited_by: current_identity) do |identity|
          identity.public_send("#{auth_mapping.account_association}=", account)
          identity.invitation_registration_required = requires_registration
          assign_tenant_to_invitee(identity, current_identity)
        end
        result.value
      else
        Vouch::Persistence.update!(account,
          invitation_token: SecureRandom.uuid, invitation_sent_at: Time.current,
          inviter: current_identity, invitation_registration_required: requires_registration)
        account
      end
    end
    run_hooks(:invitation_token_generation, identifier, invitee) { |env| env.add(invitee) }
    redirect_to root_path, notice: I18n.t('vouch.invitations.sent')
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique,
         Vouch::Persistence::Cancelled
    redirect_to root_path, notice: I18n.t('vouch.invitations.sent')
  end

  def destroy
    token = params[:invitation_token]
    if token.present?
      invitation = revocable_invitations.find_by(invitation_token: token)
      if invitation
        execution = prepare_hooks(:invitation_revocation, invitation, auth_mapping.account_for(invitation))
        committed = false
        Vouch::Persistence.transaction(invitation) do
          account = auth_mapping.account_for(invitation)
          account.lock!
          invitation.lock! unless invitation == account
          execution.run_before!
          raise ActiveRecord::Rollback if execution.halted?
          next unless revocable_invitations.where(
            auth_mapping.identity_class.primary_key => invitation.id,
            invitation_token: token
          ).exists?

          completed = false
          execution.run do
            if auth_mapping.split_model?
              invitation.destroy!
            else
              Vouch::Persistence.update!(invitation,
                invitation_token: nil, invitation_sent_at: nil)
            end
            completed = true
          end
          execution.run_on!
          raise ActiveRecord::Rollback unless completed
          committed = true
        end
        finish_lifecycle_hooks(execution, completed: committed)
      end
    end
    redirect_to root_path, notice: I18n.t('vouch.invitations.revoked')
  rescue ActiveRecord::RecordNotDestroyed, Vouch::Persistence::Cancelled
    head :unprocessable_content
  end

  def accept
    identity = auth_mapping.identity_class.find_by_invitation_token(params[:token])
    unless identity && !identity.invitation_expired?
      return redirect_to new_session_path, alert: I18n.t('vouch.invitations.invalid_token')
    end

    authentication_session.begin_invitation!(identity)
    if invitation_requires_registration?(identity)
      if auth_mapping.membership_scope?
        parent = Vouch.mapping_for(auth_mapping.parent_scope_name)
        session[Vouch::Session.key_for(parent.scope_name, :destination_scope)] = auth_scope_name.to_s
        redirect_to public_send(:"new_#{parent.helper_prefix}_registration_path")
      else
        redirect_to new_registration_path
      end
    elsif current_identity && auth_mapping.account_for(identity) == current_account
      begin
        accepted = accept_pending_invitation(current_account)
      rescue Vouch::Persistence::Cancelled
        return head :unprocessable_content
      end
      return head(:unprocessable_content) unless accepted

      redirect_to after_sign_in_path
    else
      redirect_to new_session_path, notice: I18n.t('vouch.invitations.accepted')
    end
  end

  private

  def authorize_invitation!
    raise Vouch::ConfigurationError, <<~MSG.squish
      Define #authorize_invitation! in the host invitations controller before
      creating invitations.
    MSG
  end

  def revocable_invitations
    relation = auth_mapping.identity_class.pending_invitation.where(inviter: current_identity)
    if auth_mapping.tenant?
      association = auth_mapping.identity_tenant_association.name
      relation = relation.where(association => current_identity.public_send(association))
    end
    relation
  end
end
