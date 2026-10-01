class Vouch::ImpersonationsController < ::ApplicationController
  include Vouch::Authentication
  skip_before_action :authenticate_auth_scope!
  before_action :authenticate_impersonator!, only: :create
  before_action :authenticate_impersonation_termination!, only: %i[destroy destroy_all]
  before_action :set_identity, only: :create

  def create(&response_handler)
    target = @identity
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
    respond_with_authentication_result(result, response_handler) do
      changed ? redirect_to(root_path) : head(:forbidden)
    end
  end

  def destroy(&response_handler)
    original = Vouch::ImpersonationStack.current_source(warden: warden, session: session, scope: impersonator_scope_name)
    unless original
      Vouch::ImpersonationStack.stop_all!(warden: warden, session: session, target_mapping: auth_mapping)
      return respond_with_authentication_result(Vouch::Result.invalid(reason: :invalid_impersonation), response_handler) do
        head :unprocessable_entity
      end
    end
    previous_url = Vouch::ImpersonationStack.return_to(session)
    changed = run_authentication_hooks(:impersonation_end, current_identity, original) do |env|
      committed = run_commit_hooks(:impersonation_end, *env.args, **env.kwargs) do
        true
      end
      env.abort! unless committed
      renew_authentication_session
      Vouch::ImpersonationStack.stop!(warden: warden, session: session, target_mapping: auth_mapping).present?
    end
    result = changed ? Vouch::Result.ok(original) : Vouch::Result.cancelled(record: original)
    respond_with_authentication_result(result, response_handler) do
      changed ? redirect_to(previous_url || root_path) : head(:forbidden)
    end
  end

  def destroy_all(&response_handler)
    original = Vouch::ImpersonationStack.current_source(warden: warden, session: session, scope: impersonator_scope_name)
    unless original
      Vouch::ImpersonationStack.stop_all!(warden: warden, session: session, target_mapping: auth_mapping)
      return respond_with_authentication_result(Vouch::Result.invalid(reason: :invalid_impersonation), response_handler) do
        head :unprocessable_entity
      end
    end

    previous_url = Vouch::ImpersonationStack.return_to(session)
    changed = run_authentication_hooks(:impersonation_end, current_identity, original) do |env|
      committed = run_commit_hooks(:impersonation_end, *env.args, **env.kwargs) { true }
      env.abort! unless committed
      renew_authentication_session
      Vouch::ImpersonationStack.stop_all!(warden: warden, session: session, target_mapping: auth_mapping).present?
    end
    result = changed ? Vouch::Result.ok(original) : Vouch::Result.cancelled(record: original)
    respond_with_authentication_result(result, response_handler) do
      changed ? redirect_to(previous_url || root_path) : head(:forbidden)
    end
  end

  private

  def impersonatable_identities
    auth_mapping.identity_class.all
  end

  def set_identity
    @identity = Vouch::RecordKey.find(impersonatable_identities, params[:id])
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
    if Vouch::ImpersonationStack.active?(session)
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
