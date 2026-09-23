class Vouch::OmniAuthsController < ::ApplicationController
  include Vouch::Authentication
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
    when :signed_in then redirect_after_authentication
    when :needs_two_factor then redirect_to two_factor_challenges_path
    when :needs_selection then redirect_to select_path
    else failure
    end
  end

  def link_identity(existing)
    if existing && auth_mapping.account_for_oauth_identity(existing) != current_account
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
    linked ? redirect_to(root_path, notice: I18n.t('vouch.oauth.linked')) : head(:forbidden)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique,
         Vouch::Persistence::Cancelled
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
        identity = build_registration(account)
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
    if committed
      case outcome
      when :signed_in then redirect_after_authentication
      when :needs_two_factor then redirect_to two_factor_challenges_path
      when :needs_selection then redirect_to select_path
      else failure
      end
    else
      head(:forbidden)
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique,
         Vouch::Persistence::Cancelled
    failure
  end
end
