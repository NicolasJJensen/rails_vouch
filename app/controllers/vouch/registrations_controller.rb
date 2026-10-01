class Vouch::RegistrationsController < ::ApplicationController
  include Vouch::Authentication
  prepend_before_action :require_unimpersonated_authentication!
  only_allow_unauthenticated_access

  def new
    invitation = pending_invited_identity
    oauth = pending_oauth_registration
    @account = if oauth
      auth_mapping.account_class.new_from_omniauth(oauth)
    elsif invitation && invitation_requires_registration?(invitation)
      invitation_account_for(invitation)
    else
      auth_mapping.account_class.new
    end
  end

  def create(&response_handler)
    result = oauth_registration_context? ? create_oauth_registration : create_password_registration
    respond_with_authentication_result(result, response_handler) { render_registration_result(result) }
  end

  private

  def create_password_registration
    saved = false

    invitation = pending_invited_identity
    if session[invited_user_session_key].present? && (!invitation || !invitation_requires_registration?(invitation))
      session.delete(invited_user_session_key)
      return Vouch::Result.invalid(reason: :invalid_invitation)
    end
    @account = invitation ? invitation_account_for(invitation) : auth_mapping.account_class.new(account_params)
    validate_submitted_registration_password!(@account, invitation ? invited_account_params : account_params)
    identity = nil
    outcome = nil
    committed = run_authentication_hooks_with_invitation(:sign_up, @account) do |env|
      completed = run_commit_hooks(:sign_up, *env.args, **env.kwargs) do |commit_env|
        if invitation
          @account.lock!
          invitation.lock! if invitation != @account
          unless valid_pending_invitation?(invitation) && invitation_requires_registration?(invitation)
            raise Vouch::Invitable::InvitationExpiredError
          end
          Vouch::Persistence.update!(@account, invited_account_params)
          validate_registration_authentication!(@account)
          @account.complete_registration!
          accept_pending_invitation_in_transaction(@account, invitation)
          identity = invitation
        else
          validate_registration_authentication!(@account)
          Vouch::Persistence.save!(@account)
          identity = create_registration_identity!(@account)
        end
        commit_env.add(identity)
        true
      end
      env.abort! unless completed
      saved = true
      if invitation
        session.delete(invited_user_session_key)
        publish_invitation_acceptance
      end
      clear_credential_drafts
      outcome = complete_sign_in(@account, method: :registration)
      env.add(identity)
      true
    end
    registration_result(committed, saved, outcome)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, Vouch::Persistence::Cancelled => error
    Vouch::Result.invalid(record: @account, error: error, committed: saved)
  rescue Vouch::Invitable::InvitationExpiredError
    session.delete(invited_user_session_key)
    Vouch::Result.invalid(reason: :invalid_invitation)
  end

  def create_oauth_registration
    saved = false
    oauth = pending_oauth_registration
    unless oauth
      authentication_session.clear_oauth_initiation_return_to
      return Vouch::Result.invalid(reason: :expired_oauth)
    end

    @account = auth_mapping.account_class.new_from_omniauth(oauth)
    @account.assign_attributes(account_params)
    validate_submitted_registration_password!(@account, account_params)
    identity = nil
    outcome = nil
    committed = run_authentication_hooks(:oauth_account_creation, auth_hash: oauth) do |env|
      completed = run_commit_hooks(:oauth_account_creation, *env.args, **env.kwargs) do |commit_env|
        Vouch::Persistence.save!(@account)
        Vouch::Persistence.create!(
          @account.public_send(auth_mapping.oauth_identity_association.name),
          auth_mapping.oauth_identity_class.oauth_attributes(oauth)
        )
        validate_registration_authentication!(@account, oauth: oauth)
        identity = create_registration_identity!(@account)
        commit_env.add(@account, identity)
        true
      end
      env.abort! unless completed
      saved = true
      clear_oauth_registration
      authentication_session.clear_oauth_initiation_return_to
      session[Vouch::Session.key_for(auth_scope_name, :completion)] = "sign_up"
      outcome = complete_sign_in(@account, hook: :sign_in, method: :oauth, auth_hash: oauth)
      env.add(@account, identity)
      true
    end
    registration_result(committed, saved, outcome)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, Vouch::Persistence::Cancelled => error
    Vouch::Result.invalid(record: @account, error: error, committed: saved)
  end

  def registration_result(completed, saved, outcome)
    return Vouch::Result.cancelled(record: @account, committed: false) unless saved

    result = sign_in_result(@account, completed ? outcome : :cancelled)
    result.metadata[:committed] = true
    result.metadata[:next_step] = :sign_in if result.invalid?
    result
  end

  def render_registration_result(result)
    if result.ok?
      redirect_after_authentication notice: registration_created_message
    elsif result.pending?
      redirect_to(result.metadata[:next_step] == :two_factor ? two_factor_challenges_path : select_path)
    elsif result.metadata[:committed]
      flash[:notice] = registration_created_message
      redirect_to new_session_path, alert: I18n.t('vouch.registrations.sign_in_failed')
    elsif result.metadata[:reason] == :invalid_invitation
      redirect_to new_session_path, alert: I18n.t('vouch.invitations.invalid_token')
    elsif result.metadata[:reason] == :expired_oauth
      redirect_to new_session_path, alert: I18n.t('vouch.oauth.failed')
    else
      @account.errors.add(:base, I18n.t('vouch.registrations.failed')) if @account.errors.empty?
      render :new, status: :unprocessable_entity
    end
  end

  def registration_created_message
    I18n.t('vouch.registrations.account_created', model: auth_mapping.account_class.model_name.human)
  end

  def account_params
    params.require(auth_mapping.account_param_key).permit(:email_address, :password, :password_confirmation)
  end

  def invited_account_params
    params.require(auth_mapping.account_param_key).permit(:password, :password_confirmation)
  end
end
