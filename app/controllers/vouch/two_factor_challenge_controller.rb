class Vouch::TwoFactorChallengeController < ::ApplicationController
  include Vouch::Authentication
  prepend_before_action :require_unimpersonated_authentication!

  allow_unauthenticated_access
  before_action :find_pending_account

  def index
    @credentials = eligible_credentials
    @enrollment_required = @credentials.empty? && pending_membership_requirements.present?
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
    token       = session[two_factor_token_session_key(@credential)]

    result = if token
      if membership_challenge? ? !current_membership_allows_recovery_codes? : (pending_membership_requirements && pending_membership_requirements["allow_recovery_codes"] != true)
        Vouch::BackupCodable.without_recovery_code_fallback { @credential.verify_challenge(params[:code], token: token) }
      else
        @credential.verify_challenge(params[:code], token: token)
      end
    else
      Vouch::Result.invalid
    end

    if result.ok? && @credential.reload.two_factor_enabled? && @credential.verified?
      session.delete(two_factor_token_session_key(@credential))
      proof_method = result.recovery_code? ? :recovery_code : :two_factor
      return resume_membership_challenge!(proof_method, @credential, @credential) if membership_challenge?

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
    if membership_challenge? && !membership_recovery_owner_allowed?(owner)
      result = Vouch::Result.invalid
    elsif pending_membership_requirements && pending_membership_requirements["allow_recovery_codes"] != true
      result = Vouch::Result.invalid
    else
      result = owner ? owner.consume_recovery_code!(params[:recovery_code]) : Vouch::Result.invalid
    end
    if result.ok?
      return resume_membership_challenge!(:recovery_code, nil, owner) if membership_challenge?

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
      session[two_factor_token_session_key(credential)] = result.token
      true
    else
      session.delete(two_factor_session_key)
      session.delete(two_factor_token_session_key(credential))
      redirect_to new_session_path, alert: I18n.t("vouch.two_factor.attempts_exceeded")
      false
    end
  end

  def recovery_owners
    return [] if pending_membership_requirements && pending_membership_requirements["allow_recovery_codes"] != true

    owners = []
    owners << @account if @account.respond_to?(:consume_recovery_code!)
    credentials = two_factor_credentials_for(@account).enabled.select { |credential| credential.respond_to?(:consume_recovery_code!) }
    types = Array(pending_membership_requirements&.fetch("credential_types", nil)).map { |type| type.respond_to?(:name) ? type.name : type.to_s }
    credentials.select! { |credential| types.empty? || types.include?(credential.class.name) }
    owners.concat(credentials)
    owners
  end

  def eligible_credentials
    credentials = two_factor_credentials_for(@account).enabled
    requirements = pending_membership_requirements
    return credentials unless requirements

    types = Array(requirements["credential_types"]).map { |type| type.respond_to?(:name) ? type.name : type.to_s }
    methods = Array(requirements["credential_methods"]).map(&:to_s)
    return credentials if types.empty? && methods.empty?

    credentials.reject do |credential|
      (types.any? && !types.include?(credential.class.name)) ||
        (methods.any? && !methods.include?(credential.authentication_method.to_s))
    end
  end

  def pending_membership_requirements
    pending = session[two_factor_session_key]
    pending.is_a?(Hash) ? pending["membership_mfa"] : nil
  end

  def membership_challenge?
    session[two_factor_session_key].is_a?(Hash) && session[two_factor_session_key]["membership_scope"].present?
  end

  # Linked membership scopes use the parent account's MFA routes. On success
  # we retain the account Warden session, save evidence under its namespace,
  # then return to the membership controller to bind the selected identity.
  def resume_membership_challenge!(method, credential, owner)
    context = session[two_factor_session_key]
    mapping = Vouch.mapping_for(context.fetch("membership_scope"))
    identity = mapping.identities_for(@account).detect do |candidate|
      context.fetch("identity_ids", []).include?(Vouch::RecordKey.serialize(candidate))
    end
    evidence = Vouch::AuthenticationEvidence.build(method: method, account: @account,
      credential: credential, owner: owner)
    unless identity && membership_evidence_qualifies?(mapping, identity, evidence)
      flash.now[:alert] = I18n.t("vouch.two_factor.invalid_code")
      @recovery_owners = recovery_owners if method == :recovery_code
      return render(method == :recovery_code ? :recovery : :show, status: :unprocessable_entity)
    end

    context["evidence"] = evidence
    session[Vouch::Session.key_for(auth_mapping.evidence_scope_name, :evidence)] = evidence
    session[Vouch::Session.key_for(mapping.scope_name, :selection)] = context
    session.delete(two_factor_session_key)
    flash[:notice] = I18n.t("vouch.two_factor.recovery_code_used") if method == :recovery_code
    redirect_to public_send(:"new_#{mapping.helper_prefix}_session_path")
  end

  def membership_evidence_qualifies?(mapping, identity, evidence)
    return false unless authentication_policy.respond_to?(:membership_mfa_requirements)

    tenant = mapping.tenant? ? identity.public_send(mapping.identity_tenant_association.name) : nil
    requirements = authentication_policy.membership_mfa_requirements(@account, identity: identity, tenant: tenant, controller: self)
    Vouch::AuthenticationEvidence.qualifies?(evidence, requirements, account: @account, mapping: mapping)
  end

  def membership_recovery_owner_allowed?(owner)
    return false unless owner

    mapping, identity = membership_challenge_mapping_and_identity
    return false unless mapping && identity

    evidence = Vouch::AuthenticationEvidence.build(method: :recovery_code, account: @account, owner: owner)
    membership_evidence_qualifies?(mapping, identity, evidence)
  end

  def current_membership_allows_recovery_codes?
    mapping, identity = membership_challenge_mapping_and_identity
    return false unless mapping && identity && authentication_policy.respond_to?(:membership_mfa_requirements)

    tenant = mapping.tenant? ? identity.public_send(mapping.identity_tenant_association.name) : nil
    authentication_policy.membership_mfa_requirements(@account, identity: identity, tenant: tenant, controller: self)
      .to_h.stringify_keys["allow_recovery_codes"] == true
  end

  def membership_challenge_mapping_and_identity
    context = session[two_factor_session_key]
    mapping = Vouch.mapping_for(context.fetch("membership_scope"))
    identity = mapping.identities_for(@account).detect do |candidate|
      context.fetch("identity_ids", []).include?(Vouch::RecordKey.serialize(candidate))
    end
    [mapping, identity]
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
