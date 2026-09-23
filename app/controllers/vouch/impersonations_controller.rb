class Vouch::ImpersonationsController < ::ApplicationController
  include Vouch::Authentication
  before_action :authorize_impersonation!, only: :create

  def create
    target = auth_mapping.identity_class.find(params[:id])
    original = warden.user(impersonation_scope) || current_identity
    return_path = session[impersonation_return_to_session_key] || local_referer_path
    changed = false
    hook_execution = prepare_lifecycle_hooks(:impersonation_start, current_identity, target)
    run_lifecycle_operation(hook_execution) do
      reset_session_with_preserved_keys
      clear_linked_authentication_scopes if auth_mapping.membership_scope?
      warden.set_user(original, scope: impersonation_scope, store: true)
      session[impersonation_return_to_session_key] = return_path
      if auth_mapping.membership_scope?
        target_account = auth_mapping.account_for(target)
        warden.set_user(target_account, scope: auth_mapping.parent_scope_name, store: true)
      end
      warden.set_user(target, scope: auth_scope_name, store: true)
      changed = true
    end
    finish_lifecycle_hooks(hook_execution, completed: changed)
    changed ? redirect_to(root_path) : head(:forbidden)
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: I18n.t('vouch.impersonations.not_found')
  end

  def destroy
    original = warden.user(impersonation_scope)
    return head(:unprocessable_entity) unless original
    previous_url = safe_local_path(session[impersonation_return_to_session_key])
    changed = false
    hook_execution = prepare_lifecycle_hooks(:impersonation_end, current_identity, original)
    run_lifecycle_operation(hook_execution) do
      reset_session_with_preserved_keys
      clear_linked_authentication_scopes if auth_mapping.membership_scope?
      warden.logout(impersonation_scope)
      if auth_mapping.membership_scope?
        warden.set_user(auth_mapping.account_for(original), scope: auth_mapping.parent_scope_name, store: true)
      end
      warden.set_user(original, scope: auth_scope_name, store: true)
      changed = true
    end
    finish_lifecycle_hooks(hook_execution, completed: changed)
    changed ? redirect_to(previous_url || root_path) : head(:forbidden)
  end

  def destroy_all
    destroy
  end

  private

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

  def clear_linked_authentication_scopes
    Vouch.logout_scope(warden, session, auth_mapping.parent_scope_name)
  end
end
