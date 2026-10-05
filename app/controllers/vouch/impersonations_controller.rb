class Vouch::ImpersonationsController < ::ApplicationController
  include Vouch::Authentication
  skip_before_action :authenticate_auth_scope!
  skip_before_action :validate_impersonation_context, only: :destroy_all
  before_action :authenticate_impersonator!, only: :create
  before_action :authenticate_impersonation_termination!, only: %i[destroy destroy_all]
  before_action :set_identity, only: :create

  def create
    return if performed?

    target = @vouch_identity
    original = current_impersonator
    return_path = local_referer_path
    changed = run_authentication_hooks(:impersonation_start, original, target) do |env|
      committed = run_commit_hooks(:impersonation_start, *env.args, **env.kwargs) do
        true
      end
      env.abort! unless committed
      Vouch::ImpersonationStack.start!(warden: warden, session: session,
        source_mapping: impersonator_mapping, source: original,
        target_mapping: auth_mapping, target: target, return_to: return_path) do
          renew_authentication_session
        end
      true
    end
    result = changed ? Vouch::Result.ok(target) : Vouch::Result.cancelled(record: target)
    @vouch_account = auth_mapping.split_model? ? current_account : @vouch_identity
    set_operation_result(result)
  end

  def destroy
    return if performed?

    original = Vouch::ImpersonationStack.restoration_identity(session)
    unless original
      Vouch::ImpersonationStack.stop_all!(warden: warden, session: session, target_mapping: auth_mapping)
      @vouch_identity = current_identity
      @vouch_account = current_account
      return set_operation_result(Vouch::Result.invalid(reason: :invalid_impersonation))
    end
    @impersonation_return_path = Vouch::ImpersonationStack.return_to(session)
    changed = run_authentication_hooks(:impersonation_end, current_identity, original) do |env|
      committed = run_commit_hooks(:impersonation_end, *env.args, **env.kwargs) do
        true
      end
      env.abort! unless committed
      renew_authentication_session
      Vouch::ImpersonationStack.stop!(warden: warden, session: session, target_mapping: auth_mapping).present?
    end
    result = changed ? Vouch::Result.ok(original) : Vouch::Result.cancelled(record: original)
    @vouch_identity = current_identity
    @vouch_account = current_account
    set_operation_result(result)
  end

  def destroy_all
    return if performed?

    original = Vouch::ImpersonationStack.restoration_identity(session, all: true)
    unless original
      Vouch::ImpersonationStack.stop_all!(warden: warden, session: session, target_mapping: auth_mapping)
      @vouch_identity = current_identity
      @vouch_account = current_account
      return set_operation_result(Vouch::Result.invalid(reason: :invalid_impersonation))
    end

    @impersonation_return_path = Vouch::ImpersonationStack.return_to(session)
    Vouch::ImpersonationStack.revalidate!(warden: warden, session: session) do |context|
      impersonation_allowed?(context)
    end
    changed = run_authentication_hooks(:impersonation_end, current_identity, original) do |env|
      committed = run_commit_hooks(:impersonation_end, *env.args, **env.kwargs) { true }
      env.abort! unless committed
      if Vouch::ImpersonationStack.active?(session)
        renew_authentication_session
        Vouch::ImpersonationStack.stop_all!(warden: warden, session: session, target_mapping: auth_mapping).present?
      else
        request.session_options[:renew] = true
        true
      end
    end
    result = changed ? Vouch::Result.ok(original) : Vouch::Result.cancelled(record: original)
    @vouch_identity = current_identity
    @vouch_account = current_account
    set_operation_result(result)
  end

  private

  def default_render
    return if performed?
    return super unless @_vouch_operation_result && %w[create destroy destroy_all].include?(action_name)

    if @operation_status == :ok
      redirect_to @impersonation_return_path || root_path
    elsif @failure_reason == :invalid_impersonation
      head :unprocessable_entity
    else
      head :forbidden
    end
  end

  def impersonatable_identities
    auth_mapping.identity_class.all
  end

  def set_identity
    @vouch_identity = Vouch::RecordKey.find(impersonatable_identities, params[:id])
    expose_authentication_records
  end

  def local_referer_path
    return nil if request.referer.blank?
    uri = URI.parse(request.referer)
    safe_local_path(uri.path) if uri.host.nil? || uri.host == request.host
  rescue URI::InvalidURIError
    nil
  end

  def authenticate_impersonator!
    Vouch::ImpersonationStack.discard_invalid!(warden: warden, session: session)
    if Vouch::ImpersonationStack.membership_restricted?(session)
      return head(:forbidden) unless auth_mapping.split_model?
      source = Vouch::ImpersonationStack.source_scope(session)
      requested = params[:impersonator_scope].presence
      return head(:forbidden) unless allowed_impersonator_scopes.include?(source)
      return head(:forbidden) if requested && requested != source.to_s
      return head(:forbidden) unless impersonator
      return
    end

    requested = params[:impersonator_scope].presence
    if requested
      return head(:forbidden) unless allowed_impersonator_scopes.map(&:to_s).include?(requested)
      @resolved_impersonator_scope = requested.to_sym
      return head(:forbidden) unless impersonator
      return
    end

    authenticated = allowed_impersonator_scopes.select do |scope|
      Vouch.authenticated_identity(warden, scope, controller: self)
    end
    return render(plain: "Choose an impersonator_scope", status: :unprocessable_entity) if authenticated.many?
    if authenticated.one?
      @resolved_impersonator_scope = authenticated.first
      return
    end
    return head(:unauthorized) unless allowed_impersonator_scopes.one?

    mapping = impersonator_mapping
    redirect_to mapping.route_path(:sessions, :new, self)
  end

  def authenticate_impersonation_termination!
    Vouch::ImpersonationStack.discard_invalid!(warden: warden, session: session)
    return if Vouch::ImpersonationStack.target_scope(session) == auth_scope_name

    redirect_to new_session_path
  end
end
