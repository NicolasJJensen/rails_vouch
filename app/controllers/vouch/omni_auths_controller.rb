class Vouch::OmniAuthsController < ::ApplicationController
  include Vouch::Authentication
  prepend_before_action :require_unimpersonated_authentication!, only: :callback
  allow_unauthenticated_access

  def callback
    @auth_hash = request.env['omniauth.auth']
    return failure unless @auth_hash && @auth_hash['provider'].present? && @auth_hash['uid'].present?

    oauth_identity = auth_mapping.oauth_identity_class&.find_from_omniauth(@auth_hash)
    if current_identity
      link_identity(oauth_identity)
    elsif oauth_identity
      sign_in_existing(oauth_identity)
    else
      create_account
    end
  end

  def failure
    authentication_session.clear_oauth_initiation_return_to
    redirect_to new_session_path, alert: I18n.t('vouch.oauth.failed')
  end

  private

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
    outcome = complete_sign_in(account, hook: :oauth_sign_in, method: :oauth, auth_hash: @auth_hash, refresh_oauth: refresh_oauth)
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

  def create_account
    if oauth_registration_required?
      begin_oauth_registration(@auth_hash)
      return redirect_to new_registration_path
    end

    account = auth_mapping.account_class.new_from_omniauth(@auth_hash)
    identity = nil
    outcome = nil
    committed = run_authentication_hooks(:oauth_account_creation, auth_hash: @auth_hash) do |env|
      completed = run_commit_hooks(:oauth_account_creation, *env.args, **env.kwargs) do |commit_env|
        Vouch::Persistence.save!(account)
        Vouch::Persistence.create!(
          account.public_send(auth_mapping.oauth_identity_association.name),
          auth_mapping.oauth_identity_class.oauth_attributes(@auth_hash)
        )
        identity = create_registration_identity!(account)
        commit_env.add(account, identity)
        true
      end
      env.abort! unless completed
      session[Vouch::Session.key_for(auth_scope_name, :completion)] = "sign_up"
      outcome = complete_sign_in(account, hook: :oauth_sign_in, method: :oauth,
        auth_hash: @auth_hash)
      env.add(account, identity)
      true
    end
    return oauth_registration_failed(reason: :aborted) unless committed

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
    else oauth_registration_failed(reason: :completion)
    end
  rescue ActiveRecord::RecordInvalid => error
    oauth_registration_failed(reason: :validation, error: error)
  rescue ActiveRecord::RecordNotUnique => error
    oauth_registration_failed(reason: :conflict, error: error)
  rescue Vouch::Persistence::Cancelled => error
    oauth_registration_failed(reason: :cancelled, error: error)
  end

  def oauth_registration_failed(reason:, error: nil)
    return_to = authentication_session.oauth_initiation_return_to
    authentication_session.clear_oauth_registration
    authentication_session.clear_oauth_initiation_return_to
    redirect_to return_to || new_session_path, alert: I18n.t('vouch.oauth.failed')
  end
end
