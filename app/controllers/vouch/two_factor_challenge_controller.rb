class Vouch::TwoFactorChallengeController < ::ApplicationController
  include Vouch::Authentication
  prepend_before_action :require_unimpersonated_authentication!

  allow_unauthenticated_access
  before_action :find_pending_account

  def index
    @credentials = eligible_credentials
    @enrollment_required = @credentials.empty?
    @recovery_available = recovery_owners.any?
  end

  def show
    @credential = eligible_credentials.find(params[:id])
    issue_challenge!(@credential) or return
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = I18n.t("vouch.two_factor.invalid_method")
    redirect_to two_factor_challenges_path
  end

  def send_code
    @credential = eligible_credentials.find(params[:id])
    return unless issue_challenge!(@credential)
    render :show
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = I18n.t("vouch.two_factor.invalid_method")
    redirect_to two_factor_challenges_path
  end

  def update
    @credential = eligible_credentials.find(params[:id])
    challenge = session[two_factor_token_session_key(@credential)]
    @credential.reload
    valid_period = challenge.is_a?(Hash) && challenge["enabled_at"] == @credential.two_factor_enabled_at&.utc&.iso8601(6)
    result = valid_period ? @credential.verify_challenge(params[:code], token: challenge["token"]) : Vouch::Result.invalid

    if result.ok? && @credential.reload.two_factor_enabled? && @credential.verified?
      session.delete(two_factor_token_session_key(@credential))
      proof_method = result.recovery_code? ? :recovery_code : :two_factor

      case complete_sign_in(@account, context: session[two_factor_session_key], credential: @credential,
        evidence_method: proof_method, recovery_owner: @credential)
      when :signed_in
        session.delete(two_factor_session_key)
        redirect_after_authentication
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

  # Recovery codes complete the same pending password/OAuth sign-in. They do
  # not create a second, weaker login flow or ask for the password again.
  def recovery
    @recovery_owners = recovery_owners
    return redirect_to(two_factor_challenges_path, alert: I18n.t("vouch.two_factor.recovery_unavailable")) if @recovery_owners.empty?
  end

  def consume_recovery
    owner = recovery_owner_from_params
    result = owner ? owner.consume_recovery_code!(params[:recovery_code]) : Vouch::Result.invalid
    if result.ok?

      case complete_sign_in(@account, context: session[two_factor_session_key],
        evidence_method: :recovery_code, recovery_owner: owner)
      when :signed_in
        session.delete(two_factor_session_key)
        flash[:notice] = I18n.t("vouch.two_factor.recovery_code_used")
        redirect_after_authentication
      when :needs_selection
        session.delete(two_factor_session_key)
        redirect_to select_path
      else
        redirect_to new_session_path, alert: I18n.t("vouch.two_factor.no_identity")
      end
    elsif result.locked?
      session.delete(two_factor_session_key)
      redirect_to new_session_path, alert: I18n.t("vouch.two_factor.attempts_exceeded")
    else
      @recovery_owners = recovery_owners
      flash.now[:alert] = I18n.t("vouch.two_factor.invalid_code")
      render :recovery, status: :unprocessable_entity
    end
  end

  private

  def issue_challenge!(credential)
    result = credential.challenge!
    if result.ok?
      session[two_factor_token_session_key(credential)] = { "token" => result.token,
        "enabled_at" => credential.two_factor_enabled_at&.utc&.iso8601(6) }
      true
    else
      session.delete(two_factor_session_key)
      session.delete(two_factor_token_session_key(credential))
      redirect_to new_session_path, alert: I18n.t("vouch.two_factor.attempts_exceeded")
      false
    end
  end

  def recovery_owners
    owners = []
    owners << @account if @account.respond_to?(:consume_recovery_code!)
    owners.concat(two_factor_credentials_for(@account).enabled.select { |credential| credential.respond_to?(:consume_recovery_code!) })
    owners
  end

  def eligible_credentials
    two_factor_credentials_for(@account).enabled
  end

  # A host must choose which configured set is being used. This intentionally
  # does not probe every set, which would make multiple recovery-code owners
  # ambiguous and leak which owner matched a submitted code.
  def recovery_owner_from_params
    type, kind, encoded_id = params[:recovery_owner_type].to_s.split(":", 3)
    return @account if type == "account" && @account.respond_to?(:consume_recovery_code!)
    return nil unless type == "credential"

    credential = two_factor_credentials_for(@account).enabled.find(encoded_id.presence || params[:recovery_owner_id])
    return nil unless kind.blank? || credential.model_name.singular == kind
    return credential if recovery_owners.any? { |owner| owner.class == credential.class && Vouch::RecordKey.same?(owner, credential) }

    nil
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def find_pending_account
    @account = authentication_session.load_second_factor&.account
    redirect_to new_session_path, alert: I18n.t('vouch.two_factor.session_expired') unless @account
  end
end
