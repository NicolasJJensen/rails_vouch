# frozen_string_literal: true

class Vouch::MembershipSessionsController < ::ApplicationController
  include Vouch::Authentication

  allow_unauthenticated_access
  before_action :require_account_session!

  def new
    unless auth_mapping.membership_scope?
      pending = authentication_session.load_selection
      return redirect_to(new_session_path) unless pending

      @account = pending.account
      @identities = pending_candidate_identities(@account, pending.context)
      return
    end
    @account = current_account
    @identities = candidate_identities_for(@account).to_a
    return head(:forbidden) if @identities.empty?

    context = Vouch::PendingAuthentication.build(@account, identities: @identities,
      method: :session, hook: :sign_in)
    return head(:forbidden) unless authentication_allowed?(@account, context)

    session[selection_session_key] = context
    if @identities.one?
      establish_membership(@identities.first, context)
    end
  end

  def create
    return complete_combined_scope unless auth_mapping.membership_scope?

    context = session[selection_session_key]
    account = current_account
    return head(:forbidden) unless Vouch::PendingAuthentication.valid?(context, account)

    identity = pending_candidate_identities(account, context).detect { |candidate| candidate.id.to_s == params[:identity_id].to_s }
    return head(:forbidden) unless identity

    establish_membership(identity, context)
  end

  def destroy
    hook_execution = prepare_lifecycle_hooks(:sign_out, current_identity)
    completed = false
    run_lifecycle_operation(hook_execution) do
      Vouch.logout_scope(warden, session, auth_scope_name)
      completed = true
    end
    return head(:forbidden) unless completed

    finish_lifecycle_hooks(hook_execution, completed: true)
    redirect_to after_sign_out_path
  end

  private

  def require_account_session!
    unless auth_mapping.membership_scope?
      redirect_to new_session_path unless pending_select_account
      return
    end
    return if current_account

    parent = Vouch.mapping_for(auth_mapping.parent_scope_name)
    session[Vouch::Session.key_for(parent.scope_name, :destination_scope)] = auth_scope_name.to_s
    destination = session.delete(return_to_session_key)
    session[Vouch::Session.key_for(parent.scope_name, :return_to)] = destination if destination
    redirect_to public_send(:"new_#{parent.helper_prefix}_session_path")
  end

  def complete_combined_scope
    pending = authentication_session.load_selection
    return redirect_to(new_session_path) unless pending

    identity = pending_candidate_identities(pending.account, pending.context).detect do |candidate|
      candidate.id.to_s == params[:identity_id].to_s
    end
    if identity && bind_identity(pending.account, identity, pending.context) == :signed_in
      redirect_after_authentication
    else
      redirect_to new_session_path, alert: I18n.t("vouch.user_selection.invalid_selection")
    end
  end

  def establish_membership(identity, context)
    account = current_account
    hook_execution = nil
    invitation = nil
    completed = account.with_lock(requires_new: true) do
      next false unless Vouch::PendingAuthentication.valid?(context, account)
      next false unless authentication_allowed?(account, context)
      next false unless pending_candidate_identities(account, context).any? { |candidate| candidate.id == identity.id }

      hook_execution = prepare_lifecycle_hooks(:sign_in, account, identity)
      succeeded = false
      run_lifecycle_operation(hook_execution) do
        invitation = accept_pending_invitation(account, publish: false)
        succeeded = true
      end
      succeeded
    end
    return head(:forbidden) unless completed

    reset_session_with_preserved_keys
    session.delete(selection_session_key)
    publish_invitation_acceptance(account, invitation) if invitation
    warden.set_user(identity, scope: auth_scope_name, store: true, event: :authentication)
    finish_lifecycle_hooks(hook_execution, completed: true)
    redirect_after_authentication
  rescue Vouch::Persistence::Cancelled
    head :forbidden
  end
end
