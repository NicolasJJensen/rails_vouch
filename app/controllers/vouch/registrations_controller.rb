class Vouch::RegistrationsController < ::ApplicationController
  include Vouch::Authentication
  prepend_before_action :require_unimpersonated_authentication!
  only_allow_unauthenticated_access

  def new
    if oauth_registration_context? && !authentication_session.valid_oauth_registration_context?
      clear_oauth_registration
      return redirect_to new_session_path, alert: I18n.t('vouch.oauth.context_changed')
    end
    invitation = pending_invited_identity
    @account ||= if oauth_registration_context?
      authentication_session.oauth_registration_account
    elsif invitation && invitation_requires_registration?(invitation)
      invitation_account_for(invitation)
    else
      auth_mapping.account_class.new
    end
    registration_form if registration_form_class
  rescue Vouch::RegistrationFormError => error
    clear_registration_form
    redirect_to new_registration_path, alert: I18n.t("vouch.registrations.#{error.reason}")
  end

  def create(&response_handler)
    return if performed?

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
    attributes = registration_form_class ? registration_form_params : (invitation ? invited_account_params : account_params)
    @account ||= invitation ? invitation_account_for(invitation) : auth_mapping.account_class.new
    if registration_form_class
      prepare_registration_form(attributes)
    elsif !invitation
      @account.assign_attributes(attributes)
    end
    validate_submitted_registration_password!(@account, attributes)
    identity = nil
    outcome = nil
    committed = run_authentication_hooks_with_invitation(:sign_up, @account) do |env|
      completed = run_commit_hooks(:sign_up, *env.args, **env.kwargs) do |commit_env|
        if invitation
          lock_registration_record!(@account)
          invitation.lock! if invitation != @account
          unless valid_pending_invitation?(invitation) && invitation_requires_registration?(invitation)
            raise Vouch::Invitable::InvitationExpiredError
          end
          if registration_form_class
            persist_registration_record!(@account)
          else
            Vouch::Persistence.update!(@account, invited_account_params)
          end
          validate_registration_authentication!(@account)
          @account.complete_registration!
          accept_pending_invitation_in_transaction(@account, invitation)
          identity = invitation
        else
          persist_registration_record!(@account)
          validate_registration_authentication!(@account)
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
      clear_registration_form if registration_form_class
      clear_credential_drafts
      outcome = complete_sign_in(@account, method: :registration)
      env.add(identity)
      true
    end
    registration_result(committed, saved, outcome)
  rescue Vouch::RegistrationFormError, ActiveModel::ValidationError, Vouch::OperationFailed => error
    registration_form_failure(error).tap { |result| result.metadata[:committed] = saved }
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, Vouch::Persistence::Cancelled => error
    return registration_form_failure(error) if registration_form_class && !saved
    Vouch::Result.invalid(record: @account, error: error, committed: saved)
  rescue Vouch::Invitable::InvitationExpiredError
    session.delete(invited_user_session_key)
    Vouch::Result.invalid(reason: :invalid_invitation)
  end

  def create_oauth_registration
    saved = false
    unless authentication_session.valid_oauth_registration_context?
      clear_oauth_registration
      return Vouch::Result.invalid(reason: :context_changed)
    end
    @account ||= authentication_session.oauth_registration_account
    attributes = registration_form_class ? registration_form_params : (invitation_registration? ? invited_account_params : account_params)
    if registration_form_class
      prepare_registration_form(attributes)
    else
      @account.assign_attributes(attributes)
    end
    retained = authentication_session.retain_oauth_registration_attributes!(@account)
    unless retained.ok?
      @account.errors.add(:base, I18n.t("vouch.oauth.registration_too_large"))
      return Vouch::Result.invalid(record: @account, reason: :registration_too_large)
    end
    validate_submitted_registration_password!(@account, attributes)
    expired = pending_oauth_providers.select { |provider| provider[:expired] }
    if expired.any?
      @account.errors.add(:base, I18n.t("vouch.oauth.expired_providers"))
      return Vouch::Result.invalid(record: @account, reason: :expired_providers, providers: expired)
    end
    oauth_hashes = authentication_session.oauth_registration_hashes
    oauth = oauth_hashes.first
    lifecycle = oauth ? :oauth_account_creation : :sign_up
    identity = nil
    outcome = nil
    committed = run_authentication_hooks_with_invitation(lifecycle, @account, auth_hash: oauth) do |env|
      completed = run_commit_hooks(lifecycle, *env.args, **env.kwargs) do |commit_env|
        identity = persist_oauth_registration!(@account, oauth_hashes)
        commit_env.add(identity)
        true
      end
      env.abort! unless completed
      saved = true
      clear_oauth_registration
      clear_registration_form if registration_form_class
      if @completed_invitation_acceptance
        authentication_session.clear_invitation
        publish_invitation_acceptance
      end
      authentication_session.clear_oauth_initiation_return_to
      session[Vouch::Session.key_for(auth_scope_name, :completion)] = "sign_up"
      outcome = complete_sign_in(@account, hook: :sign_in, method: oauth ? :oauth : :registration,
        auth_hash: oauth, auth_hashes: oauth_hashes)
      env.add(identity)
      true
    end
    registration_result(committed, saved, outcome)
  rescue Vouch::RegistrationFormError, ActiveModel::ValidationError, Vouch::OperationFailed => error
    registration_form_failure(error).tap { |result| result.metadata[:committed] = saved }
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, Vouch::Persistence::Cancelled => error
    return registration_form_failure(error) if registration_form_class && !saved
    Vouch::Result.invalid(record: @account, error: error, committed: saved)
  rescue Vouch::Invitable::InvitationExpiredError
    authentication_session.clear_invitation
    Vouch::Result.invalid(reason: :invalid_invitation)
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
    elsif registration_form_class && %i[expired context_changed].include?(result.metadata[:reason])
      clear_registration_form
      redirect_to new_registration_path, alert: I18n.t("vouch.registrations.#{result.metadata[:reason]}")
    elsif result.metadata[:reason] == :context_changed
      redirect_to new_session_path, alert: I18n.t('vouch.oauth.context_changed')
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
    params.fetch(auth_mapping.account_param_key, ActionController::Parameters.new).permit(:password, :password_confirmation)
  end
end
