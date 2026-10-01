class Vouch::TwoFactorChallengeController < ::ApplicationController
  include Vouch::Authentication
  prepend_before_action :require_unimpersonated_authentication!

  allow_unauthenticated_access
  before_action :find_pending_account
  before_action :set_credential, only: %i[show send_code update]
  before_action :set_recovery_owner, only: :consume_recovery
  helper_method :additional_authentication?

  def index
    @credentials = eligible_credentials
    @enrollment_required = @credentials.empty?
    @recovery_available = recovery_owners.any?
  end

  def show
    return if performed?

    issue_challenge!(@credential) or return
  end

  def send_code
    return if performed?

    return unless issue_challenge!(@credential)
    render :show
  end

  def update(&response_handler)
    return if performed?

    challenge = session[two_factor_token_session_key(@credential)]
    @credential.reload
    valid_period = challenge.is_a?(Hash) && challenge["enabled_at"] == @credential.two_factor_enabled_at&.utc&.iso8601(6)
    result = valid_period ? @credential.verify_challenge(params[:code], token: challenge["token"]) : Vouch::Result.invalid(record: @credential)

    if result.ok? && (!@credential.reload.two_factor_enabled? || !@credential.verified?)
      result = Vouch::Result.invalid(record: @credential)
    end

    if result.ok?
      session.delete(two_factor_token_session_key(@credential))
      method = result.recovery_code? ? :recovery_code : :two_factor
      return complete_additional_authentication(method, @credential, @credential, &response_handler) if additional_authentication?
      return finish_sign_in(method, @credential, @credential, &response_handler)
    end

    if result.locked? || @credential.two_factor_locked?
      return additional_authentication_failed(result, &response_handler) if additional_authentication?
      clear_challenge_context
      respond_with_authentication_result(result, response_handler) do
        redirect_to new_session_path, alert: I18n.t("vouch.two_factor.attempts_exceeded")
      end
    else
      respond_with_authentication_result(result, response_handler) do
        flash.now[:alert] = I18n.t("vouch.two_factor.invalid_code")
        render :show, status: :unprocessable_entity
      end
    end
  end

  # Recovery codes complete the same pending password/OAuth sign-in. They do
  # not create a second, weaker login flow or ask for the password again.
  def recovery
    @recovery_owners = recovery_owners
    return redirect_to(two_factor_challenges_path, alert: I18n.t("vouch.two_factor.recovery_unavailable")) if @recovery_owners.empty?
  end

  def consume_recovery(&response_handler)
    return if performed?

    owner = @recovery_owner
    result = owner ? owner.consume_recovery_code(params[:recovery_code]) : Vouch::Result.invalid
    if result.ok?
      return complete_additional_authentication(:recovery_code, nil, owner, &response_handler) if additional_authentication?
      return finish_sign_in(:recovery_code, nil, owner, &response_handler)
    end
    if result.locked?
      return additional_authentication_failed(result, &response_handler) if additional_authentication?
      clear_challenge_context
      respond_with_authentication_result(result, response_handler) do
        redirect_to new_session_path, alert: I18n.t("vouch.two_factor.attempts_exceeded")
      end
    else
      @recovery_owners = recovery_owners
      respond_with_authentication_result(result, response_handler) do
        flash.now[:alert] = I18n.t("vouch.two_factor.invalid_code")
        render :recovery, status: :unprocessable_entity
      end
    end
  end

  def destroy(&response_handler)
    return if performed?

    destination = additional_authentication? ? @authentication_context.fetch("return_to", "/") : new_session_path
    clear_challenge_context
    respond_with_authentication_result(Vouch::Result.ok(@account), response_handler) { redirect_to destination }
  end

  private

  def finish_sign_in(method, credential, owner, &response_handler)
    outcome = complete_sign_in(@account, context: session[two_factor_session_key], credential: credential,
      evidence_method: method, recovery_owner: owner)
    session.delete(two_factor_session_key) if %i[signed_in needs_selection].include?(outcome)
    respond_with_authentication_result(sign_in_result(@account, outcome), response_handler) do
      case outcome
      when :signed_in then redirect_after_authentication
      when :needs_selection then redirect_to select_path
      else redirect_to new_session_path, alert: I18n.t("vouch.two_factor.no_identity")
      end
    end
  end

  def set_credential
    @credential = eligible_credentials.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to two_factor_challenges_path, alert: I18n.t("vouch.two_factor.invalid_method")
  end

  def additional_authentication?
    @authentication_context&.fetch("additional_mfa", false) == true
  end

  def complete_additional_authentication(method, credential, owner, &response_handler)
    @account.reload
    principal = current_account
    unless principal && Vouch::RecordKey.same?(principal, @account, model: @account.class) &&
        Vouch::PendingAuthentication.valid?(@authentication_context, @account, hook: :two_factor_verification) &&
        additional_context_current?
      return additional_authentication_failed(Vouch::Result.invalid, &response_handler)
    end
    proof = Vouch::AuthenticationEvidence.build(method: method, account: @account,
      credential: (credential unless method == :recovery_code), owner: owner)
    return additional_authentication_failed(Vouch::Result.invalid, &response_handler) unless Vouch::AuthenticationEvidence.valid?(proof, account: @account, mapping: auth_mapping)

    authentication_session.store_evidence!(proof, account: @account)
    run_hooks(:two_factor_verification, @account, current_identity, credential, evidence: proof, additional: true)
    destination = @authentication_context.fetch("return_to", "/")
    clear_challenge_context
    result = Vouch::Result.ok(@account, evidence: proof, credential: credential)
    respond_with_authentication_result(result, response_handler) { redirect_to destination }
  end

  def additional_context_current?
    @authentication_context["authentication_context"] == authentication_session.context_id
  end

  def additional_authentication_failed(result = Vouch::Result.invalid, &response_handler)
    destination = @authentication_context.fetch("return_to", "/")
    clear_challenge_context
    respond_with_authentication_result(result, response_handler) do
      redirect_to destination, alert: I18n.t("vouch.two_factor.invalid_code")
    end
    false
  end

  def clear_challenge_context
    session.delete(two_factor_session_key)
    prefix = Vouch::Session.dynamic_key_for(auth_scope_name, "two_factor_token.")
    session.keys.each { |key| session.delete(key) if key.to_s.start_with?(prefix) }
  end

  def additional_return_path(value = params[:return_to])
    candidate = url_from(value)
    return "/" unless candidate
    uri = URI.parse(candidate)
    return candidate if uri.relative? && candidate.start_with?("/") && !candidate.start_with?("//")
    candidate if uri.scheme == request.scheme && uri.host == request.host && uri.port == request.port
  rescue URI::InvalidURIError
    "/"
  end

  def issue_challenge!(credential)
    result = credential.challenge
    if result.ok?
      session[two_factor_token_session_key(credential)] = { "token" => result.token,
        "enabled_at" => credential.two_factor_enabled_at&.utc&.iso8601(6) }
      true
    else
      return additional_authentication_failed if additional_authentication?
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

  def set_recovery_owner
    @recovery_owner = select_recovery_owner(recovery_owners, account: @account,
      type: params[:recovery_owner_type], id: params[:recovery_owner_id])
  end

  def find_pending_account
    previous_context = session[two_factor_session_key]
    pending = authentication_session.load_second_factor
    if pending
      @account = pending.account
      @authentication_context = pending.context
      if additional_authentication? && (!current_account || !Vouch::RecordKey.same?(current_account, @account, model: @account.class) || !additional_context_current?)
        clear_challenge_context
        @account = nil
      end
    elsif action_name == "index" && current_account
      @account = current_account
      evidence_key = Vouch::Session.key_for(auth_mapping.evidence_scope_name, :evidence)
      proofs = Vouch::AuthenticationEvidence.current(session[evidence_key], account: @account, mapping: auth_mapping)
      proofs.empty? ? session.delete(evidence_key) : session[evidence_key] = proofs
      @authentication_context = Vouch::PendingAuthentication.build(@account, identities: [current_identity], method: :additional_mfa, hook: :two_factor_verification)
      @authentication_context["additional_mfa"] = true
      @authentication_context["authentication_context"] = authentication_session.context_id
      @authentication_context["return_to"] = additional_return_path || "/"
      session[two_factor_session_key] = @authentication_context
    end
    if !@account && current_account && previous_context.is_a?(Hash) && previous_context["additional_mfa"] == true
      clear_challenge_context
      return redirect_to(additional_return_path(previous_context["return_to"]) || "/",
        alert: I18n.t('vouch.two_factor.session_expired'))
    end
    redirect_to new_session_path, alert: I18n.t('vouch.two_factor.session_expired') unless @account
  end
end
