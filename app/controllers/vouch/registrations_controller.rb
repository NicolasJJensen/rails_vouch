class Vouch::RegistrationsController < ::ApplicationController
  include Vouch::Authentication
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

  def create
    return create_oauth_registration if oauth_registration_context?

    invitation = pending_invited_identity
    if session[invited_user_session_key].present? && (!invitation || !invitation_requires_registration?(invitation))
      session.delete(invited_user_session_key)
      return redirect_to new_session_path, alert: I18n.t('vouch.invitations.invalid_token')
    end
    @account = invitation ? invitation_account_for(invitation) : auth_mapping.account_class.new(account_params)
    identity = nil
    outcome = nil
    committed = run_authentication_hooks(:sign_up, @account) do |env|
      completed = run_commit_hooks(:sign_up, *env.args, **env.kwargs) do |commit_env|
        if invitation
          @account.lock!
          invitation.lock! if invitation != @account
          unless valid_pending_invitation?(invitation) && invitation_requires_registration?(invitation)
            raise Vouch::Invitable::InvitationExpiredError
          end
          Vouch::Persistence.update!(@account, invited_account_params)
          @account.complete_registration!
          invitation.accept_invitation!
          identity = invitation
        else
          Vouch::Persistence.save!(@account)
          identity = build_registration(@account)
        end
        commit_env.add(identity)
        true
      end
      env.abort! unless completed
      if invitation
        session.delete(invited_user_session_key)
        run_hooks(:invitation_acceptance, identity) { |invitation_env| invitation_env.add(@account) }
      end
      clear_credential_drafts
      outcome = complete_sign_in(@account, method: :registration)
      env.add(identity)
      true
    end
    return head(:forbidden) unless committed

    case outcome
    when :signed_in then redirect_after_authentication notice: I18n.t('vouch.registrations.account_created')
    when :needs_two_factor then redirect_to two_factor_challenges_path
    when :needs_selection then redirect_to select_path
    else head :forbidden
    end
  rescue ActiveRecord::RecordInvalid, Vouch::Persistence::Cancelled
    render :new, status: 422
  rescue Vouch::Invitable::InvitationExpiredError
    session.delete(invited_user_session_key)
    redirect_to new_session_path, alert: I18n.t('vouch.invitations.invalid_token')
  end

  private

  def create_oauth_registration
    oauth = pending_oauth_registration
    return redirect_to(new_session_path, alert: I18n.t('vouch.oauth.failed')) unless oauth

    @account = auth_mapping.account_class.new_from_omniauth(oauth)
    @account.assign_attributes(account_params)
    identity = nil
    outcome = nil
    committed = run_authentication_hooks(:oauth_account_creation, auth_hash: oauth) do |env|
      completed = run_commit_hooks(:oauth_account_creation, *env.args, **env.kwargs) do |commit_env|
        Vouch::Persistence.save!(@account)
        Vouch::Persistence.create!(
          @account.public_send(auth_mapping.oauth_identity_association.name),
          auth_mapping.oauth_identity_class.oauth_attributes(oauth)
        )
        identity = build_registration(@account)
        commit_env.add(@account, identity)
        true
      end
      env.abort! unless completed
      clear_oauth_registration
      session[Vouch::Session.key_for(auth_scope_name, :completion)] = "sign_up"
      outcome = complete_sign_in(@account, hook: :oauth_sign_in, method: :oauth, auth_hash: oauth)
      env.add(@account, identity)
      true
    end
    return head(:forbidden) unless committed

    case outcome
    when :signed_in then redirect_after_authentication notice: I18n.t('vouch.registrations.account_created')
    when :needs_two_factor then redirect_to two_factor_challenges_path
    when :needs_selection then redirect_to select_path
    else head :forbidden
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, Vouch::Persistence::Cancelled
    render :new, status: 422
  end

  def account_params
    params.require(auth_mapping.account_param_key).permit(:email_address, :password, :password_confirmation)
  end

  def invited_account_params
    params.require(auth_mapping.account_param_key).permit(:password, :password_confirmation)
  end
end
