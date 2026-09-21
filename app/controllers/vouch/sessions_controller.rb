class Vouch::SessionsController < Vouch::BaseController

  only_allow_unauthenticated_access only: %i[new create]

  def new; end

  def create
    session.delete(two_factor_session_key)
    session.delete(selection_session_key)
    session.delete(signed_in_via_session_key)
    warden.logout(account_scope_name)
    account = warden.authenticate(scope: auth_scope_name, run_callbacks: false)
    # Warden caches strategy success even when the strategy disables storage.
    warden.set_user(nil, scope: auth_scope_name, store: false, run_callbacks: false)

    unless account
      flash.now[:alert] = failed_login_message
      render :new, status: 422
      return
    end

    case complete_sign_in(account)
    when :signed_in
      redirect_back_or_default after_sign_in_path
    when :needs_two_factor
      redirect_to two_factor_challenges_path
    when :needs_selection
      redirect_to select_path
    else
      flash.now[:alert] = I18n.t("vouch.oauth.no_identity")
      render :new, status: 422
    end
  end

  def destroy
    signed_out = false
    hook_execution = prepare_lifecycle_hooks(:sign_out, current_identity)
    run_lifecycle_operation(hook_execution) do
      warden.logout(auth_scope_name, account_scope_name, impersonation_scope)
      session.keys.grep(/\Awarden\.#{Regexp.escape(auth_scope_name.to_s)}\./).each { |key| session.delete(key) }
      signed_out = true
    end
    return head(:forbidden) unless signed_out

    finish_lifecycle_hooks(hook_execution, completed: true)
    redirect_to after_sign_out_path, notice: I18n.t("vouch.sessions.signed_out")
  end
end
