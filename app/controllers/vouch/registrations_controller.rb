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
    hook_execution = nil
    committed = @account.class.transaction(requires_new: true) do
      completed = false
      hook_execution = prepare_lifecycle_hooks(:sign_up, @account)
      next false unless run_lifecycle_operation(hook_execution) do |env|
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
        env.add(identity)
        completed = true
      end
      completed
    end
    return head(:forbidden) unless committed

    if invitation
      session.delete(invited_user_session_key)
      run_hooks(:invitation_acceptance, identity) { |env| env.add(@account) }
    end
    clear_credential_drafts
    outcome = complete_sign_in(@account, method: :registration)
    # Sign-up describes account registration, not the optional follow-on
    # identity selection. It has completed once its transaction commits; run
    # the after phase after the sign-in attempt so any session state is ready.
    finish_lifecycle_hooks(hook_execution, completed: committed)
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
    hook_execution = nil
    committed = @account.class.transaction(requires_new: true) do
      hook_execution = prepare_lifecycle_hooks(:oauth_account_creation, auth_hash: oauth)
      next false unless run_lifecycle_operation(hook_execution) do |env|
        Vouch::Persistence.save!(@account)
        Vouch::Persistence.create!(
          @account.public_send(auth_mapping.oauth_identity_association.name),
          auth_mapping.oauth_identity_class.oauth_attributes(oauth)
        )
        identity = build_registration(@account)
        env.add(@account, identity)
      end
      @account.persisted?
    end
    return head(:forbidden) unless committed

    clear_oauth_registration
    session[Vouch::Session.key_for(auth_scope_name, :completion)] = "sign_up"
    outcome = complete_sign_in(@account, hook: :oauth_sign_in, method: :oauth, auth_hash: oauth)
    finish_lifecycle_hooks(hook_execution, completed: committed)
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
