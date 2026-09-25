class Vouch::ImpersonationsController < ::ApplicationController
  include Vouch::Authentication
  skip_before_action :authenticate_auth_scope!
  before_action :authenticate_impersonator!, only: :create
  before_action :authenticate_impersonation_termination!, only: %i[destroy destroy_all]
  before_action :authorize_impersonation!, only: :create

  def create
    target = Vouch::RecordKey.find(impersonatable_identities, params[:id])
    original = current_impersonator
    return_path = Vouch::ImpersonationStack.return_to(session) || local_referer_path
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
    changed ? redirect_to(root_path) : head(:forbidden)
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: I18n.t('vouch.impersonations.not_found')
  end

  def destroy
    original = Vouch::ImpersonationStack.current_source(warden: warden, session: session, scope: impersonator_scope_name)
    unless original
      Vouch::ImpersonationStack.stop_all!(warden: warden, session: session, target_mapping: auth_mapping)
      return head(:unprocessable_entity)
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
    changed ? redirect_to(previous_url || root_path) : head(:forbidden)
  end

  def destroy_all
    original = Vouch::ImpersonationStack.current_source(warden: warden, session: session, scope: impersonator_scope_name)
    unless original
      Vouch::ImpersonationStack.stop_all!(warden: warden, session: session, target_mapping: auth_mapping)
      return head(:unprocessable_entity)
    end

    previous_url = Vouch::ImpersonationStack.return_to(session)
    changed = run_authentication_hooks(:impersonation_end, current_identity, original) do |env|
      committed = run_commit_hooks(:impersonation_end, *env.args, **env.kwargs) { true }
      env.abort! unless committed
      renew_authentication_session
      Vouch::ImpersonationStack.stop_all!(warden: warden, session: session, target_mapping: auth_mapping).present?
    end
    changed ? redirect_to(previous_url || root_path) : head(:forbidden)
  end

  private

  def impersonatable_identities
    auth_mapping.identity_class.all
  end

  def authorize_impersonation!
    head :forbidden
  end

  def local_referer_path
    return nil if request.referer.blank?
    uri = URI.parse(request.referer)
    safe_local_path(uri.path) if uri.host.nil? || uri.host == request.host
  rescue URI::InvalidURIError
    nil
  end

  def authenticate_impersonator!
    return if current_impersonator

    mapping = impersonator_mapping
    session[Vouch::Session.key_for(mapping.scope_name, :return_to)] = request.fullpath if request.get?
    redirect_to public_send(:"new_#{mapping.helper_prefix}_session_path")
  end

  def authenticate_impersonation_termination!
    return if Vouch::ImpersonationStack.active?(session, scope: auth_scope_name)

    redirect_to new_session_path
  end
end
