class Vouch::InvitationsController < ::ApplicationController
  include Vouch::Authentication
  allow_unauthenticated_access only: [:accept, :reject]
  before_action :set_invitation, only: [:create, :resend, :accept, :reject, :destroy]

  before_action :require_account_invitation_access!, only: :accept

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

  def destroy(&response_handler)
    return if performed?
    result = revoke_invitation
    respond_with_authentication_result(result, response_handler) do
      if result.ok?
        redirect_to root_path, notice: I18n.t("vouch.invitations.revoked")
      elsif result.error || result.cancelled?
        render plain: I18n.t("vouch.invitations.update_failed"), status: :unprocessable_content
      else
        redirect_to root_path, alert: I18n.t("vouch.invitations.not_found")
      end
    end
  end

  def accept(&response_handler)
    return if performed?
    if request.get? && @invitation && !@invitation.invitation_expired?
      @receiving_account = current_account
      @registration_required = invitation_requires_registration?(@invitation)
      return render :accept
    end

    result = choose_invitation_acceptance
    respond_with_authentication_result(result, response_handler) do
      if result.ok?
        redirect_to (auth_mapping.membership_scope? ? new_session_path : after_sign_in_path), notice: I18n.t("vouch.invitations.joined")
      elsif result.pending?
        mapping = if auth_mapping.membership_scope?
          session[Vouch::Session.key_for(auth_mapping.parent_scope_name, :destination_scope)] = auth_scope_name.to_s
          Vouch.mapping_for(auth_mapping.parent_scope_name)
        else
          auth_mapping
        end
        endpoint = result.metadata[:next_step] == :registration ? :registrations : :sessions
        redirect_to mapping.route_path(endpoint, :new, self)
      elsif result.error || result.cancelled?
        render plain: I18n.t("vouch.invitations.update_failed"), status: :unprocessable_content
      else
        redirect_to new_session_path, alert: I18n.t("vouch.invitations.invalid_token")
      end
    end
  end

  def reject(&response_handler)
    return if performed?
    result = reject_invitation
    respond_with_authentication_result(result, response_handler) do
      if result.ok?
        redirect_to root_path, notice: I18n.t("vouch.invitations.rejected")
      else
        redirect_to new_session_path, alert: I18n.t("vouch.invitations.invalid_token")
      end
    end
  end

  private

  def require_account_invitation_access!
    if request.post? && Vouch::ImpersonationStack.membership_restricted?(session)
      head :forbidden
    end
  end

  def revoke_invitation
    return Vouch::Result.invalid(reason: :not_found) unless @invitation
    token = params[:invitation_token]
    account = auth_mapping.account_for(@invitation)
    completed = run_authentication_hooks(:invitation_revocation, @invitation, account) do |env|
      committed = run_commit_hooks(:invitation_revocation, @invitation, account) do
        account.lock!
        @invitation.lock! unless @invitation == account
        next false unless revocable_invitations.where(Vouch::RecordKey.attributes_for(@invitation))
          .where(invitation_token: token).exists?
        if auth_mapping.split_model?
          @invitation.destroy!
        else
          Vouch::Persistence.update!(@invitation, invitation_token: nil, invitation_sent_at: nil)
        end
        true
      end
      env.abort! unless committed
      true
    end
    completed ? Vouch::Result.ok(@invitation) : Vouch::Result.cancelled(record: @invitation)
  rescue ActiveRecord::RecordNotDestroyed, Vouch::Persistence::Cancelled => error
    Vouch::Result.invalid(record: @invitation, error: error)
  end

  def choose_invitation_acceptance
    return Vouch::Result.invalid(reason: :invalid_token) unless @invitation && !@invitation.invitation_expired?
    return Vouch::Result.invalid(reason: :invalid_choice) unless request.post?
    choice = params[:choice].to_s
    case choice
    when "new"
      return Vouch::Result.invalid(reason: :invalid_choice) if current_account || !invitation_requires_registration?(@invitation)
      authentication_session.begin_invitation!(@invitation, choice: choice)
      Vouch::Result.pending(@invitation, next_step: :registration)
    when "existing"
      return Vouch::Result.invalid(reason: :invalid_choice) if current_account
      authentication_session.begin_invitation!(@invitation, choice: choice)
      Vouch::Result.pending(@invitation, next_step: :sign_in)
    when "current"
      return Vouch::Result.invalid(reason: :invalid_choice) unless current_account
      authentication_session.begin_invitation!(@invitation, choice: choice)
      return Vouch::Result.invalid(reason: :invalid_token) unless invitation_acceptance_allowed?(@invitation, current_account)
      accepted = accept_pending_invitation(current_account)
      accepted ? Vouch::Result.ok(accepted) : Vouch::Result.cancelled(record: @invitation)
    else
      Vouch::Result.invalid(reason: :invalid_choice)
    end
  rescue Vouch::Persistence::Cancelled, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    Vouch::Result.invalid(record: @invitation, error: error)
  end

  def reject_invitation
    return Vouch::Result.invalid(reason: :invalid_token) unless @invitation && !@invitation.invitation_expired?
    account = auth_mapping.account_for(@invitation)
    result = nil
    token = @invitation.invitation_token
    completed = run_authentication_hooks(:invitation_rejection, @invitation, account) do |env|
      committed = run_commit_hooks(:invitation_rejection, @invitation, account) do
        result = @invitation.reject_invitation
        result.ok?
      end
      env.abort! unless committed
      payload = session[invited_user_session_key]
      authentication_session.clear_invitation if payload.is_a?(Hash) && payload["token"] == token
      true
    end
    completed ? result : Vouch::Result.cancelled(record: @invitation)
  end

  def create_invitation
    identifier = params[:email_address] || params[:identifier]
    transaction_record = auth_mapping.account_class.new
    invitee = Vouch::Persistence.transaction(transaction_record) do
      account = @account
      Vouch::Persistence.save!(account) if account.new_record?
      account.lock!
      if auth_mapping.split_model?
        existing = existing_identity_for_invitation(account)
        if existing && existing.invitation_rejected_at.nil?
          error = existing.invitation_token.present? && existing.invitation_accepted_at.nil? ?
            Vouch::Invitable::InvitationExistsError : Vouch::Invitable::AlreadyJoinedError
          raise error.new(existing)
        else
          @invitation.public_send("#{auth_mapping.account_association}=", account)
          assign_tenant_to_invitee(@invitation, current_identity)
          @invitation.assign_attributes(invitation_token: SecureRandom.uuid,
            invitation_sent_at: Time.current, invitation_rejected_at: nil, inviter: current_identity)
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
  rescue Vouch::OperationFailed => error
    error.result
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
    elsif %w[accept reject].include?(action_name)
      auth_mapping.identity_class.find_by_invitation_token(params[:token])
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
