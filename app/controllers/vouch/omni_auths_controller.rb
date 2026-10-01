class Vouch::OmniAuthsController < ::ApplicationController
  include Vouch::Authentication
  prepend_before_action :require_unimpersonated_authentication!, only: :callback
  allow_unauthenticated_access

  def callback(&response_handler)
    @auth_hash = request.env['omniauth.auth']
    return failure unless @auth_hash && @auth_hash['provider'].present? && @auth_hash['uid'].present?

    @oauth_initiation = authentication_session.consume_oauth_initiation(@auth_hash)
    return oauth_request_failed(:invalid_request, response_handler) unless @oauth_initiation

    oauth_identity = auth_mapping.oauth_identity_class&.find_from_omniauth(@auth_hash)
    case @oauth_initiation["purpose"]
    when "link"
      unless authentication_session.oauth_initiation_matches_account?(@oauth_initiation, current_account)
        return oauth_request_failed(:context_changed, response_handler)
      end
      link_identity(oauth_identity)
    when "sign_in"
      return oauth_request_failed(:context_changed, response_handler) if current_identity
      return oauth_request_failed(:not_registered, response_handler) unless oauth_identity

      sign_in_existing(oauth_identity)
    when "register"
      if current_identity || @oauth_initiation["account_id"] ||
          @oauth_initiation["invitation"] != session[invited_user_session_key] ||
          !ActiveSupport::SecurityUtils.secure_compare(@oauth_initiation["context_id"].to_s, authentication_session.context_id)
        return oauth_request_failed(:context_changed, response_handler)
      end
      return oauth_request_failed(:registration_conflict, response_handler) if oauth_identity

      create_account(response_handler)
    else
      oauth_request_failed(:invalid_request, response_handler)
    end
  end

  def failure
    authentication_session.clear_oauth_initiation_return_to
    redirect_to new_session_path, alert: I18n.t('vouch.oauth.failed')
  end

  private

  def oauth_request_failed(reason, response_handler)
    result = Vouch::Result.invalid(reason: reason)
    respond_with_authentication_result(result, response_handler) do
      authentication_session.clear_oauth_initiation_return_to
      destination = %i[registration_conflict identity_mismatch too_many_providers expired_providers registration_too_large].include?(reason) ? new_registration_path : new_session_path
      redirect_to destination, alert: I18n.t("vouch.oauth.#{reason}")
    end
  end

  def sign_in_existing(oauth_identity)
    account = auth_mapping.account_for_oauth_identity(oauth_identity)
    return failure unless account
    context = {'method' => 'oauth', 'provider' => @auth_hash['provider']}
    return failure unless authentication_allowed?(account, context)

    finish_oauth(account, refresh_oauth: true)
  rescue ActiveRecord::RecordInvalid
    failure
  end

  def finish_oauth(account, refresh_oauth: false)
    session[Vouch::Session.key_for(auth_scope_name, :completion)] = "sign_in"
    outcome = complete_sign_in(account, hook: :sign_in, method: :oauth, auth_hash: @auth_hash, refresh_oauth: refresh_oauth)
    case outcome
    when :signed_in
      authentication_session.clear_oauth_initiation_return_to
      redirect_after_authentication
    when :needs_two_factor
      authentication_session.clear_oauth_initiation_return_to
      redirect_to two_factor_challenges_path
    when :needs_selection
      authentication_session.clear_oauth_initiation_return_to
      redirect_to select_path
    else failure
    end
  end

  def link_identity(existing)
    if existing && auth_mapping.account_for_oauth_identity(existing) != current_account
      authentication_session.clear_oauth_initiation_return_to
      return redirect_to root_path, alert: I18n.t('vouch.oauth.already_linked')
    end
    linked = run_authentication_hooks(:oauth_link, current_identity, auth_hash: @auth_hash) do |env|
      completed = run_commit_hooks(:oauth_link, *env.args, **env.kwargs) do
        unless existing
          Vouch::Persistence.create!(
            current_account.public_send(auth_mapping.oauth_identity_association.name),
            auth_mapping.oauth_identity_class.oauth_attributes(@auth_hash)
          )
        end
        true
      end
      env.abort! unless completed
      true
    end
    authentication_session.clear_oauth_initiation_return_to
    linked ? redirect_to(root_path, notice: I18n.t('vouch.oauth.linked')) : head(:forbidden)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique,
         Vouch::Persistence::Cancelled
    authentication_session.clear_oauth_initiation_return_to
    redirect_to root_path, alert: I18n.t('vouch.oauth.already_linked')
  end

  def create_account(response_handler = nil)
    saved = false
    pending = begin_oauth_registration(@auth_hash, reconnect_uid: @oauth_initiation["reconnect_uid"])
    return oauth_request_failed(pending.metadata[:reason], response_handler) unless pending.ok?
    if oauth_registration_required?
      return redirect_to new_registration_path
    end
    if pending_oauth_providers.any? { |provider| provider[:expired] }
      return oauth_request_failed(:expired_providers, response_handler)
    end

    account = pending.value
    oauth_hashes = authentication_session.oauth_registration_hashes
    identity = nil
    outcome = nil
    committed = run_authentication_hooks_with_invitation(:oauth_account_creation, account, auth_hash: @auth_hash) do |env|
      completed = run_commit_hooks(:oauth_account_creation, *env.args, **env.kwargs) do |commit_env|
        identity = persist_oauth_registration!(account, oauth_hashes)
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
      session[Vouch::Session.key_for(auth_scope_name, :completion)] = "sign_up"
      outcome = complete_sign_in(account, hook: :sign_in, method: :oauth,
        auth_hash: @auth_hash, auth_hashes: oauth_hashes)
      env.add(identity)
      true
    end
    return saved ? registered_account_sign_in_failed : oauth_registration_failed(reason: :aborted) unless committed

    case outcome
    when :signed_in
      authentication_session.clear_oauth_initiation_return_to
      redirect_after_authentication
    when :needs_two_factor
      authentication_session.clear_oauth_initiation_return_to
      redirect_to two_factor_challenges_path
    when :needs_selection
      authentication_session.clear_oauth_initiation_return_to
      redirect_to select_path
    else registered_account_sign_in_failed
    end
  rescue ActiveRecord::RecordInvalid => error
    saved ? registered_account_sign_in_failed : oauth_registration_failed(reason: :validation, error: error)
  rescue ActiveRecord::RecordNotUnique => error
    saved ? registered_account_sign_in_failed : oauth_registration_failed(reason: :conflict, error: error)
  rescue Vouch::Persistence::Cancelled => error
    saved ? registered_account_sign_in_failed : oauth_registration_failed(reason: :cancelled, error: error)
  rescue Vouch::Invitable::InvitationExpiredError
    authentication_session.clear_invitation
    oauth_request_failed(:invalid_request, response_handler)
  end

  def registered_account_sign_in_failed
    authentication_session.clear_oauth_registration
    authentication_session.clear_oauth_initiation_return_to
    flash[:notice] = I18n.t('vouch.registrations.account_created', model: auth_mapping.account_class.model_name.human)
    redirect_to new_session_path, alert: I18n.t('vouch.registrations.sign_in_failed')
  end

  def oauth_registration_failed(reason:, error: nil)
    return_to = authentication_session.oauth_initiation_return_to
    authentication_session.clear_oauth_initiation_return_to
    redirect_to return_to || new_session_path, alert: I18n.t('vouch.oauth.failed')
  end
end
