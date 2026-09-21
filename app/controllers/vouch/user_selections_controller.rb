class Vouch::UserSelectionsController < Vouch::BaseController
  allow_unauthenticated_access
  before_action :require_pending_select!

  def index
    pending = authentication_session.load_selection
    return redirect_to(new_session_path) unless pending

    @account = pending.account
    @identities = pending_candidate_identities(@account, pending.context)
  end

  def create
    pending = authentication_session.load_selection
    return redirect_to(new_session_path) unless pending

    account = pending.account
    context = pending.context
    identity = pending_candidate_identities(account, context).detect { |candidate| candidate.id.to_s == params[:identity_id].to_s }
    if identity && bind_identity(account, identity, context) == :signed_in
      redirect_back_or_default after_sign_in_path
    else
      redirect_to new_session_path, alert: I18n.t('vouch.user_selection.invalid_selection')
    end
  end
end
