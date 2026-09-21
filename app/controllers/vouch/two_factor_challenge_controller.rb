class Vouch::TwoFactorChallengeController < Vouch::BaseController

  allow_unauthenticated_access
  before_action :find_pending_account

  def index
    @credentials = two_factor_credentials_for(@account).enabled
  end

  def show
    @credential = two_factor_credentials_for(@account).enabled.find(params[:id])
    issue_challenge!(@credential) or return
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = I18n.t("vouch.two_factor.invalid_method")
    redirect_to two_factor_challenges_path
  end

  def send_code
    @credential = two_factor_credentials_for(@account).enabled.find(params[:id])
    return unless issue_challenge!(@credential)
    render :show
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = I18n.t("vouch.two_factor.invalid_method")
    redirect_to two_factor_challenges_path
  end

  def update
    @credential = two_factor_credentials_for(@account).enabled.find(params[:id])
    token       = session[two_factor_token_session_key(@credential)]

    result = token ? @credential.verify_challenge(params[:code], token: token) : Vouch::Result.invalid

    if result.ok? && @credential.reload.two_factor_enabled? && @credential.verified?
      session.delete(two_factor_token_session_key(@credential))
      case complete_sign_in(@account, context: session[two_factor_session_key], credential: @credential)
      when :signed_in
        session.delete(two_factor_session_key)
        redirect_back_or_default after_sign_in_path
      when :needs_selection
        session.delete(two_factor_session_key)
        redirect_to select_path
      else
        redirect_to new_session_path, alert: I18n.t("vouch.two_factor.no_identity")
      end
    elsif result.locked? || @credential.two_factor_locked?
      session.delete(two_factor_session_key)
      session.delete(two_factor_token_session_key(@credential))
      redirect_to new_session_path, alert: I18n.t("vouch.two_factor.attempts_exceeded")
    else
      flash.now[:alert] = I18n.t("vouch.two_factor.invalid_code")
      render :show, status: 422
    end
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = I18n.t("vouch.two_factor.invalid_method")
    redirect_to two_factor_challenges_path
  end

  private

  def issue_challenge!(credential)
    result = credential.challenge!
    if result.ok?
      session[two_factor_token_session_key(credential)] = result.token
      true
    else
      session.delete(two_factor_session_key)
      session.delete(two_factor_token_session_key(credential))
      redirect_to new_session_path, alert: I18n.t("vouch.two_factor.attempts_exceeded")
      false
    end
  end

    def find_pending_account
      @account = authentication_session.load_second_factor&.account
      redirect_to new_session_path, alert: I18n.t('vouch.two_factor.session_expired') unless @account
  end
end
