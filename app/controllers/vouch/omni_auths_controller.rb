class Vouch::OmniAuthsController < Vouch::BaseController
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

  def finish_oauth(account, refresh_oauth: false, lifecycle_execution: nil, lifecycle_completed: false)
    outcome = complete_sign_in(account, hook: :oauth_sign_in, method: :oauth, auth_hash: @auth_hash, refresh_oauth: refresh_oauth)
    finish_lifecycle_hooks(lifecycle_execution, completed: lifecycle_completed) if lifecycle_execution
    case outcome
    when :signed_in then redirect_back_or_default after_sign_in_path
    when :needs_two_factor then redirect_to two_factor_challenges_path
    when :needs_selection then redirect_to select_path
    else failure
    end
  end

  def link_identity(existing)
    if existing && auth_mapping.account_for_oauth_identity(existing) != current_account
      return redirect_to root_path, alert: I18n.t('vouch.oauth.already_linked')
    end
    hook_execution = nil
    linked = current_account.class.transaction(requires_new: true) do
      completed = false
      hook_execution = prepare_lifecycle_hooks(:oauth_link, current_identity, auth_hash: @auth_hash)
      next false unless run_lifecycle_operation(hook_execution) do
        unless existing
          Vouch::Persistence.create!(
            current_account.public_send(auth_mapping.oauth_identity_association.name),
            auth_mapping.oauth_identity_class.oauth_attributes(@auth_hash)
          )
        end
        completed = true
      end
      completed
    end
    finish_lifecycle_hooks(hook_execution, completed: linked)
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
    hook_execution = nil
    committed = auth_mapping.account_class.transaction(requires_new: true) do
      hook_execution = prepare_lifecycle_hooks(:oauth_account_creation, auth_hash: @auth_hash)
      next false unless run_lifecycle_operation(hook_execution) do |env|
        Vouch::Persistence.save!(account)
        Vouch::Persistence.create!(
          account.public_send(auth_mapping.oauth_identity_association.name),
          auth_mapping.oauth_identity_class.oauth_attributes(@auth_hash)
        )
        identity = build_registration(account)
        env.add(account, identity)
      end
      account&.persisted?
    end
    committed ? finish_oauth(account, lifecycle_execution: hook_execution, lifecycle_completed: committed) : head(:forbidden)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique,
         Vouch::Persistence::Cancelled
    failure
  end
end
