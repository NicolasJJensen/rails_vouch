class Vouch::SessionsController < ::ApplicationController
  include Vouch::Authentication
  prepend_before_action :require_unimpersonated_authentication!, only: %i[new create]

  only_allow_unauthenticated_access only: %i[new create]

  def new; end

  def create
    session[Vouch::Session.key_for(auth_scope_name, :completion)] = "sign_in"
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
      redirect_after_authentication
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
    signed_out = run_authentication_hooks(:sign_out, current_identity) do |env|
      committed = run_commit_hooks(:sign_out, *env.args, **env.kwargs) do
        true
      end
      env.abort! unless committed
      Vouch.logout_scope(warden, session, auth_scope_name)
      true
    end
    return head(:forbidden) unless signed_out

    redirect_to after_sign_out_path, notice: I18n.t("vouch.sessions.signed_out")
  end
end
