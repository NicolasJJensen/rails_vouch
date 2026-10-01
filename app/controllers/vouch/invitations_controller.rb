class Vouch::InvitationsController < ::ApplicationController
  include Vouch::Authentication
  allow_unauthenticated_access only: :accept
  before_action :set_invitation, only: [:create, :resend]

  def new; end

  def create(&response_handler)
    return if performed?

    result = create_invitation
    respond_with_authentication_result(result, response_handler) do
      render_invitation_delivery_result(result)
    end
  end

  def resend(&response_handler)
    return if performed?

    result = resend_invitation
    respond_with_authentication_result(result, response_handler) do
      render_invitation_delivery_result(result)
    end
  end


  def destroy
    token = params[:invitation_token]
    if token.present?
      invitation = revocable_invitations.find_by(invitation_token: token)
      if invitation
        committed = run_authentication_hooks(:invitation_revocation, invitation, auth_mapping.account_for(invitation)) do |env|
          succeeded = run_commit_hooks(:invitation_revocation, *env.args, **env.kwargs) do
            account = auth_mapping.account_for(invitation)
            account.lock!
            invitation.lock! unless invitation == account
            next false unless revocable_invitations.where(
              auth_mapping.identity_class.primary_key => invitation.id,
              invitation_token: token
            ).exists?

            if auth_mapping.split_model?
              invitation.destroy!
            else
              Vouch::Persistence.update!(invitation,
                invitation_token: nil, invitation_sent_at: nil)
            end
            true
          end
          env.abort! unless succeeded
          true
        end
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
        redirect_to parent.route_path(:registrations, :new, self)
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

  def create_invitation
    identifier = params[:email_address] || params[:identifier]
    transaction_record = auth_mapping.account_class.new
    invitee = Vouch::Persistence.transaction(transaction_record) do
      account = @account
      Vouch::Persistence.save!(account) if account.new_record?
      account.lock!
      if auth_mapping.split_model?
        existing = existing_identity_for_invitation(account)
        if existing
          error = existing.invitation_token.present? && existing.invitation_accepted_at.nil? ?
            Vouch::Invitable::InvitationExistsError : Vouch::Invitable::AlreadyJoinedError
          raise error.new(existing)
        else
          @invitation.public_send("#{auth_mapping.account_association}=", account)
          assign_tenant_to_invitee(@invitation, current_identity)
          @invitation.assign_attributes(invitation_token: SecureRandom.uuid,
            invitation_sent_at: Time.current, inviter: current_identity)
          Vouch::Persistence.save!(@invitation)
          @invitation
        end
      else
        if account.invitation_token.present?
          raise Vouch::Invitable::InvitationExistsError.new(account)
        elsif !account.registration_required?
          raise Vouch::Invitable::AlreadyJoinedError.new(account)
        end
        Vouch::Persistence.update!(account,
          invitation_token: SecureRandom.uuid, invitation_sent_at: Time.current,
          inviter: current_identity)
        account
      end
    end
    run_hooks(:invitation_token_generation, identifier, invitee) { |env| env.add(invitee) } if invitee
    Vouch::Result.ok(invitee)
  rescue Vouch::Invitable::AlreadyJoinedError => error
    Vouch::Result.invalid(record: error.invitation, error: error, reason: :already_joined)
  rescue Vouch::Invitable::InvitationExistsError => error
    Vouch::Result.invalid(record: error.invitation, error: error, reason: :already_invited)
  rescue ActiveRecord::RecordInvalid => error
    Vouch::Result.invalid(record: error.record, error: error)
  rescue ActiveRecord::RecordNotUnique, Vouch::Persistence::Cancelled => error
    Vouch::Result.invalid(error: error)
  end

  def resend_invitation
    return Vouch::Result.invalid(reason: :not_found) unless @invitation

    @invitation.reissue_invitation!
    identifier = auth_mapping.account_for(@invitation).email_address
    run_hooks(:invitation_token_generation, identifier, @invitation) { |env| env.add(@invitation) }
    Vouch::Result.ok(@invitation)
  rescue Vouch::Invitable::InvitationExpiredError => error
    Vouch::Result.invalid(record: @invitation, error: error, reason: :invalid_token)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, Vouch::Persistence::Cancelled => error
    Vouch::Result.invalid(record: @invitation, error: error)
  end

  def render_invitation_delivery_result(result)
    if result.ok?
      redirect_to root_path, notice: I18n.t('vouch.invitations.sent')
    else
      message = result.metadata[:record]&.errors&.full_messages&.to_sentence.presence
      reason = result.metadata[:reason] || :failed
      redirect_to root_path, alert: message || I18n.t("vouch.invitations.#{reason}", default: I18n.t("vouch.invitations.failed"))
    end
  end

  def set_invitation
    @invitation = if action_name == "create"
      @account = build_invited_account(params[:email_address] || params[:identifier])
      if auth_mapping.split_model?
        existing = existing_identity_for_invitation(@account) if @account.persisted?
        existing || auth_mapping.identity_class.new(inviter: current_identity).tap do |invitation|
          invitation.public_send("#{auth_mapping.account_association}=", @account)
          assign_tenant_to_invitee(invitation, current_identity) if auth_mapping.tenant?
        end
      else
        @account
      end
    else
      revocable_invitations.find_by(invitation_token: params[:invitation_token]) if params[:invitation_token].present?
    end
  end

  def revocable_invitations
    relation = auth_mapping.identity_class.pending_invitation.where(inviter: current_identity)
    if auth_mapping.tenant?
      association = auth_mapping.identity_tenant_association.name
      relation = relation.where(association => current_identity.public_send(association))
    end
    relation
  end

  def existing_identity_for_invitation(account)
    relation = auth_mapping.identities_for(account)
    return relation.first unless auth_mapping.tenant?

    association = auth_mapping.identity_tenant_association.name
    relation.find_by(association => current_identity.public_send(association))
  end
end
