class Vouch::RegistrationsController < ::ApplicationController
  include Vouch::Authentication
  prepend_before_action :require_unimpersonated_authentication!
  only_allow_unauthenticated_access

  before_action :set_account, only: [:new, :create]

  def new
  end

  def create(&block)
    return if performed?

    result = if oauth_registration_context?
      create_oauth_registration(&block)
    else
      create_password_registration(&block)
    end
    set_operation_result(result)
  end

  private

  def set_account
    if oauth_registration_context? && !authentication_session.valid_oauth_registration_context?
      clear_oauth_registration
      return redirect_to new_session_path, alert: I18n.t('vouch.oauth.context_changed')
    end

    invitation = pending_invited_identity
    @vouch_account = if oauth_registration_context?
      authentication_session.oauth_registration_account
    elsif invitation && invitation_requires_registration?(invitation)
      invitation_account_for(invitation)
    else
      auth_mapping.account_class.new
    end
    expose_authentication_records
  end

  def default_render
    return if performed?
    return super unless action_name == "create" && @_vouch_operation_result

    render_registration_result(@_vouch_operation_result)
  end

  def create_password_registration(&block)
    saved = false

    invitation = pending_invited_identity
    if session[invited_user_session_key].present? && (!invitation || !invitation_requires_registration?(invitation))
      session.delete(invited_user_session_key)
      return Vouch::Result.invalid(reason: :invalid_invitation)
    end
    attributes = block ? {} : (invitation ? invited_account_params : account_params)
    @vouch_account.assign_attributes(attributes) unless invitation
    expose_authentication_records
    validate_submitted_registration_password!(@vouch_account, attributes)
    identity = nil
    outcome = nil
    committed = run_authentication_hooks_with_invitation(:sign_up, @vouch_account) do |env|
      completed = run_commit_hooks(:sign_up, *env.args, **env.kwargs) do |commit_env|
        if invitation
          lock_registration_record!(@vouch_account)
          invitation.lock! if invitation != @vouch_account
          unless valid_pending_invitation?(invitation) && invitation_requires_registration?(invitation)
            raise Vouch::Invitable::InvitationExpiredError
          end
          @vouch_account.assign_attributes(attributes) unless block
          persist_registration_record!(@vouch_account, &block)
          validate_registration_authentication!(@vouch_account)
          @vouch_account.complete_registration!
          accept_pending_invitation_in_transaction(@vouch_account, invitation)
          identity = invitation
        else
          persist_registration_record!(@vouch_account, &block)
          validate_registration_authentication!(@vouch_account)
          identity = create_registration_identity!(@vouch_account)
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
      outcome = complete_sign_in(@vouch_account, method: :registration)
      env.add(identity)
      true
    end
    @vouch_identity = identity
    registration_result(committed, saved, outcome)
  rescue ActiveModel::ValidationError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, Vouch::OperationFailed => error
    registration_failure(error, committed: saved)
  rescue ActiveRecord::RecordNotSaved => error
    registration_failure(error, committed: saved, status: :cancelled)
  rescue Vouch::Invitable::InvitationExpiredError
    session.delete(invited_user_session_key)
    Vouch::Result.invalid(reason: :invalid_invitation)
  end

  def create_oauth_registration(&block)
    saved = false
    unless authentication_session.valid_oauth_registration_context?
      clear_oauth_registration
      return Vouch::Result.invalid(reason: :context_changed)
    end
    attributes = block ? {} : (invitation_registration? ? invited_account_params : account_params)
    @vouch_account.assign_attributes(attributes)
    expose_authentication_records
    retained = authentication_session.retain_oauth_registration_attributes!(@vouch_account)
    unless retained.ok?
      @vouch_account.errors.add(:base, I18n.t("vouch.oauth.registration_too_large"))
      return Vouch::Result.invalid(record: @vouch_account, reason: :registration_too_large)
    end
    validate_submitted_registration_password!(@vouch_account, attributes)
    expired = pending_oauth_providers.select { |provider| provider[:expired] }
    if expired.any?
      @vouch_account.errors.add(:base, I18n.t("vouch.oauth.expired_providers"))
      return Vouch::Result.invalid(record: @vouch_account, reason: :expired_providers, providers: expired)
    end
    oauth_hashes = authentication_session.oauth_registration_hashes
    oauth = oauth_hashes.first
    lifecycle = oauth ? :oauth_account_creation : :sign_up
    identity = nil
    outcome = nil
    committed = run_authentication_hooks_with_invitation(lifecycle, @vouch_account, auth_hash: oauth) do |env|
      completed = run_commit_hooks(lifecycle, *env.args, **env.kwargs) do |commit_env|
        identity = persist_oauth_registration!(@vouch_account, oauth_hashes, &block)
        commit_env.add(identity)
        true
      end
      env.abort! unless completed
      saved = true
      clear_oauth_registration
      if @completed_invitation_acceptance
        authentication_session.clear_invitation
        publish_invitation_acceptance
      end
      authentication_session.clear_oauth_initiation_return_to
      session[Vouch::Session.key_for(auth_scope_name, :completion)] = "sign_up"
      outcome = complete_sign_in(@vouch_account, hook: :sign_in, method: oauth ? :oauth : :registration,
        auth_hash: oauth, auth_hashes: oauth_hashes)
      env.add(identity)
      true
    end
    @vouch_identity = identity
    registration_result(committed, saved, outcome)
  rescue ActiveModel::ValidationError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, Vouch::OperationFailed => error
    registration_failure(error, committed: saved)
  rescue ActiveRecord::RecordNotSaved => error
    registration_failure(error, committed: saved, status: :cancelled)
  rescue Vouch::Invitable::InvitationExpiredError
    authentication_session.clear_invitation
    Vouch::Result.invalid(reason: :invalid_invitation)
  end

  def registration_result(completed, saved, outcome)
    return Vouch::Result.cancelled(record: @vouch_account, committed: false) unless saved

    result = sign_in_result(@vouch_account, completed ? outcome : :cancelled)
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
    elsif result.metadata[:reason] == :context_changed
      redirect_to new_session_path, alert: I18n.t('vouch.oauth.context_changed')
    else
      @vouch_account.errors.add(:base, I18n.t('vouch.registrations.failed')) if @vouch_account.errors.empty?
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
