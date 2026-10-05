class Vouch::SessionsController < ::ApplicationController
  include Vouch::Authentication
  skip_before_action :validate_impersonation_context, only: :destroy
  prepend_before_action :require_unimpersonated_authentication!, only: %i[new create]

  only_allow_unauthenticated_access only: %i[new create]
  before_action :set_confirmation_scope, only: %i[confirmation confirm cancel_confirmation]
  helper_method :confirmation_scope_name, :confirmation_mfa_path

  def new; end

  def create
    return if performed?

    session[Vouch::Session.key_for(auth_scope_name, :completion)] = "sign_in"
    session.delete(two_factor_session_key)
    session.delete(selection_session_key)
    session.delete(signed_in_via_session_key)
    warden.logout(account_scope_name)
    @vouch_account = warden.authenticate(scope: auth_scope_name, run_callbacks: false)
    # Warden caches strategy success even when the strategy disables storage.
    warden.set_user(nil, scope: auth_scope_name, store: false, run_callbacks: false)

    return set_operation_result(Vouch::Result.invalid(reason: :invalid_credentials)) unless @vouch_account

    outcome = complete_sign_in(@vouch_account)
    @vouch_identity = current_identity if outcome == :signed_in
    set_operation_result(sign_in_result(@vouch_account, outcome))
  end

  def destroy
    return if performed?

    identity = current_identity
    @vouch_account = current_account
    signed_out = run_authentication_hooks(:sign_out, identity) do |env|
      committed = run_commit_hooks(:sign_out, *env.args, **env.kwargs) do
        true
      end
      env.abort! unless committed
      Vouch.logout_scope(warden, session, auth_scope_name)
      true
    end
    @vouch_identity = identity
    result = signed_out ? Vouch::Result.ok(identity) : Vouch::Result.cancelled(record: identity)
    set_operation_result(result)
  end

  def confirmation
    return if performed?

    key = Vouch::Session.key_for(confirmation_scope_name, :confirmation_pending)
    pending = session[key]
    if pending && !valid_recent_authentication_pending?(pending, scope: confirmation_scope_name)
      session.delete(key)
      return set_operation_result(Vouch::Result.invalid(reason: :expired))
    end
    session[key] ||= { "context" => recent_authentication_context(confirmation_scope_name),
      "issued_at" => Time.current.to_f, "return_to" => recent_authentication_return_path(params[:return_to]) }
  end

  def confirm
    return if performed?

    key = Vouch::Session.key_for(confirmation_scope_name, :confirmation_pending)
    pending = session[key]
    unless valid_recent_authentication_pending?(pending, scope: confirmation_scope_name)
      session.delete(key)
      return set_operation_result(Vouch::Result.invalid(reason: :expired))
    end

    result = verify_authentication_confirmation(@confirmation_actor)
    if result.ok? && (!result.value.is_a?(@confirmation_actor.class) ||
        !Vouch::RecordKey.same?(result.value, @confirmation_actor) || result.metadata[:method].blank?)
      result = Vouch::Result.invalid(record: @confirmation_actor, reason: :invalid_confirmation_proof)
    end
    if result.ok?
      completed = run_authentication_hooks(:authentication_confirmation, @confirmation_actor) do |env|
        committed = run_commit_hooks(:authentication_confirmation, @confirmation_actor) do
          @confirmation_actor.reload
          valid_recent_authentication_pending?(pending, scope: confirmation_scope_name)
        end
        @confirmation_actor.reload
        env.abort! unless committed && valid_recent_authentication_pending?(pending, scope: confirmation_scope_name)
        record_recent_authentication(scope: confirmation_scope_name, method: result.metadata.fetch(:method))
        session.delete(key)
        true
      end
      result = Vouch::Result.cancelled(record: @confirmation_actor) unless completed
    end
    @confirmation_return_path = recent_authentication_return_path(pending["return_to"])
    set_operation_result(result)
  end

  def cancel_confirmation
    return if performed?

    pending = session.delete(Vouch::Session.key_for(confirmation_scope_name, :confirmation_pending))
    @confirmation_return_path = recent_authentication_return_path(pending&.fetch("return_to", nil))
    set_operation_result(Vouch::Result.cancelled)
  end

  private

  def default_render
    return if performed?
    return super unless @_vouch_operation_result

    case action_name
    when "create"
      if @operation_status == :ok
        redirect_after_authentication
      elsif @next_step == :two_factor
        redirect_to two_factor_challenges_path
      elsif @next_step == :selection
        redirect_to select_path
      else
        flash.now[:alert] = @failure_reason == :invalid_credentials ? failed_login_message : I18n.t("vouch.oauth.no_identity")
        render :new, status: :unprocessable_entity
      end
    when "destroy"
      if @operation_status == :ok
        redirect_to after_sign_out_path, notice: I18n.t("vouch.sessions.signed_out")
      else
        head :forbidden
      end
    when "confirmation"
      redirect_to "/", alert: I18n.t("vouch.confirmation.expired")
    when "confirm"
      if @operation_status == :ok
        redirect_to @confirmation_return_path
      elsif @failure_reason == :expired
        redirect_to "/", alert: I18n.t("vouch.confirmation.expired")
      else
        flash.now[:alert] = I18n.t("vouch.confirmation.failed")
        render :confirmation, status: :unprocessable_entity
      end
    when "cancel_confirmation"
      redirect_to @confirmation_return_path
    else
      super
    end
  end

  def confirmation_scope_name
    @confirmation_scope_name
  end

  def confirmation_mfa_path
    return if Vouch::ImpersonationStack.active?(session)
    helper = auth_mapping.route_helper(:two_factor_challenges, :index)
    return unless _routes.url_helpers.respond_to?(helper)
    pending = session[Vouch::Session.key_for(confirmation_scope_name, :confirmation_pending)]
    _routes.url_helpers.public_send(helper, return_to: recent_authentication_return_path(pending&.fetch("return_to", nil)))
  end

  def set_confirmation_scope
    @confirmation_scope_name = params[:confirmation_scope].presence&.to_sym || auth_scope_name
    mapping = Vouch.mapping_for(@confirmation_scope_name)
    unless mapping.evidence_scope_name == auth_mapping.evidence_scope_name && recent_authentication_context(@confirmation_scope_name)
      return head :forbidden
    end
    @confirmation_actor = recent_authentication_actor(@confirmation_scope_name)
    @vouch_account = @confirmation_actor
    expose_authentication_records
  rescue ArgumentError
    head :forbidden
  end

  def verify_authentication_confirmation(actor)
    Vouch::Persistence.transaction(actor) do
      actor.lock!
      next Vouch::Result.locked(record: actor) if actor.respond_to?(:locked?) && actor.locked?
      if actor.respond_to?(:authenticate) && actor.authenticate(params[:password].to_s)
        actor.successful_login! if actor.respond_to?(:successful_login!)
        Vouch::Result.ok(actor, method: :password)
      else
        actor.failed_login! if actor.respond_to?(:failed_login!)
        Vouch::Result.invalid(record: actor)
      end
    end
  rescue ActiveRecord::RecordInvalid => error
    Vouch::Result.invalid(record: error.record, error: error)
  rescue ActiveRecord::RecordNotSaved => error
    raise unless error.record
    Vouch::Result.cancelled(record: error.record, error: error)
  end

end
