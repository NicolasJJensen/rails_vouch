class Vouch::OmniAuthsController < ::ApplicationController
  include Vouch::Authentication
  allow_unauthenticated_access

  def callback(&response_handler)
    return if performed?
    @auth_hash = request.env['omniauth.auth']
    result = oauth_callback_result
    respond_with_authentication_result(result, response_handler) { render_oauth_result(result) }
  end

  def failure(&response_handler)
    return if performed?
    result = Vouch::Result.invalid(reason: :failed, error: request.env['omniauth.error'], request_failure: true)
    respond_with_authentication_result(result, response_handler) { render_oauth_result(result) }
  end

  private

  def oauth_callback_result
    unless @auth_hash && @auth_hash['provider'].present? && @auth_hash['uid'].present?
      return oauth_request_failed(:failed)
    end
    Vouch::ImpersonationStack.discard_invalid!(warden: warden, session: session)
    @oauth_initiation = authentication_session.consume_oauth_initiation(@auth_hash)
    return oauth_request_failed(:invalid_request) unless @oauth_initiation
    if Vouch::ImpersonationStack.active?(session) &&
        (Vouch::ImpersonationStack.membership_restricted?(session) || @oauth_initiation['purpose'] != 'link')
      return Vouch::Result.invalid(reason: :impersonating, forbidden: true)
    end

    oauth_identity = auth_mapping.oauth_identity_class&.find_from_omniauth(@auth_hash)
    case @oauth_initiation['purpose']
    when 'link'
      unless authentication_session.oauth_initiation_matches_account?(@oauth_initiation, current_account)
        return oauth_request_failed(:context_changed)
      end
      link_identity(oauth_identity)
    when 'sign_in'
      return oauth_request_failed(:context_changed) if current_identity
      return oauth_request_failed(:not_registered) unless oauth_identity
      sign_in_existing(oauth_identity)
    when 'register'
      if current_identity || @oauth_initiation['account_id'] ||
          @oauth_initiation['invitation'] != session[invited_user_session_key] ||
          !ActiveSupport::SecurityUtils.secure_compare(@oauth_initiation['context_id'].to_s, authentication_session.context_id)
        return oauth_request_failed(:context_changed)
      end
      return oauth_request_failed(:registration_conflict) if oauth_identity
      create_account
    else
      oauth_request_failed(:invalid_request)
    end
  end

  def oauth_request_failed(reason)
    Vouch::Result.invalid(reason: reason, request_failure: true)
  end

  def sign_in_existing(oauth_identity)
    account = auth_mapping.account_for_oauth_identity(oauth_identity)
    return oauth_request_failed(:failed) unless account
    context = {'method' => 'oauth', 'provider' => @auth_hash['provider']}
    return Vouch::Result.invalid(record: account, operation: :sign_in, reason: :denied) unless authentication_allowed?(account, context)

    session[Vouch::Session.key_for(auth_scope_name, :completion)] = 'sign_in'
    outcome = complete_sign_in(account, hook: :sign_in, method: :oauth, auth_hash: @auth_hash, refresh_oauth: true)
    result = sign_in_result(account, outcome)
    result.metadata[:operation] = :sign_in
    result
  rescue ActiveRecord::RecordInvalid => error
    Vouch::Result.invalid(record: account, operation: :sign_in, error: error)
  end

  def link_identity(existing)
    if existing && auth_mapping.account_for_oauth_identity(existing) != current_account
      return Vouch::Result.invalid(operation: :link, reason: :already_linked, record: existing)
    end
    identity = existing
    linked = run_authentication_hooks(:oauth_link, current_identity, auth_hash: @auth_hash) do |env|
      completed = run_commit_hooks(:oauth_link, *env.args, **env.kwargs) do
        identity ||= Vouch::Persistence.create!(
          current_account.public_send(auth_mapping.oauth_identity_association.name),
          auth_mapping.oauth_identity_class.oauth_attributes(@auth_hash)
        )
        true
      end
      env.abort! unless completed
      true
    end
    linked ? Vouch::Result.ok(identity, operation: :link) : Vouch::Result.cancelled(operation: :link, record: current_account)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, Vouch::Persistence::Cancelled => error
    Vouch::Result.invalid(operation: :link, reason: :already_linked, record: current_account, error: error)
  end

  def create_account
    saved = false
    pending = begin_oauth_registration(@auth_hash, reconnect_uid: @oauth_initiation['reconnect_uid'])
    return oauth_request_failed(pending.metadata[:reason]) unless pending.ok?
    account = pending.value
    return Vouch::Result.pending(account, operation: :registration, next_step: :registration) if oauth_registration_required?
    return oauth_request_failed(:expired_providers) if pending_oauth_providers.any? { |provider| provider[:expired] }

    oauth_hashes = authentication_session.oauth_registration_hashes
    outcome = nil
    committed = run_authentication_hooks_with_invitation(:oauth_account_creation, account, auth_hash: @auth_hash) do |env|
      identity = nil
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
      session[Vouch::Session.key_for(auth_scope_name, :completion)] = 'sign_up'
      outcome = complete_sign_in(account, hook: :sign_in, method: :oauth,
        auth_hash: @auth_hash, auth_hashes: oauth_hashes)
      env.add(identity)
      true
    end
    unless committed
      return Vouch::Result.cancelled(operation: :registration, record: account, committed: saved, reason: :aborted)
    end
    result = sign_in_result(account, outcome)
    result.metadata.merge!(operation: :registration, committed: saved)
    result
  rescue ActiveRecord::RecordInvalid => error
    Vouch::Result.invalid(operation: :registration, record: account, committed: saved, reason: :validation, error: error)
  rescue ActiveRecord::RecordNotUnique => error
    Vouch::Result.invalid(operation: :registration, record: account, committed: saved, reason: :conflict, error: error)
  rescue Vouch::Persistence::Cancelled => error
    Vouch::Result.cancelled(operation: :registration, record: account, committed: saved, reason: :cancelled, error: error)
  rescue Vouch::Invitable::InvitationExpiredError
    authentication_session.clear_invitation
    oauth_request_failed(:invalid_request)
  end

  def render_oauth_result(result)
    return head(:forbidden) if result.metadata[:forbidden]
    reason = result.metadata[:reason]
    if result.metadata[:request_failure]
      authentication_session.clear_oauth_initiation_return_to
      destination = %i[registration_conflict identity_mismatch too_many_providers expired_providers registration_too_large].include?(reason) ? new_registration_path : new_session_path
      return redirect_to destination, alert: I18n.t("vouch.oauth.#{reason}")
    end
    if result.metadata[:operation] == :link
      authentication_session.clear_oauth_initiation_return_to
      return redirect_to(root_path, notice: I18n.t('vouch.oauth.linked')) if result.ok?
      return head(:forbidden) if result.cancelled?
      return redirect_to(root_path, alert: I18n.t('vouch.oauth.already_linked'))
    end
    if result.pending?
      destination = case result.metadata[:next_step]
                    when :registration then new_registration_path
                    when :two_factor then two_factor_challenges_path
                    when :selection then select_path
                    end
      authentication_session.clear_oauth_initiation_return_to unless result.metadata[:next_step] == :registration
      return redirect_to destination
    end
    if result.ok?
      authentication_session.clear_oauth_initiation_return_to
      return redirect_after_authentication
    end
    if result.metadata[:operation] == :registration
      return registered_account_sign_in_failed if result.metadata[:committed]
      options = {reason: reason || :failed}
      options[:error] = result.error if result.error
      return oauth_registration_failed(**options)
    end
    authentication_session.clear_oauth_initiation_return_to
    redirect_to new_session_path, alert: I18n.t('vouch.oauth.failed')
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
