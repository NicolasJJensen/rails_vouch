# frozen_string_literal: true

class Vouch::MembershipSessionsController < ::ApplicationController
  include Vouch::Authentication

  allow_unauthenticated_access
  before_action :require_unimpersonated_selection!, only: %i[new create]
  before_action :require_account_session!

  def new(&response_handler)
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
      establish_membership(@identities.first, context, &response_handler)
    end
  end

  def create(&response_handler)
    return complete_combined_scope(&response_handler) unless auth_mapping.membership_scope?

    context = session[selection_session_key]
    account = current_account
    unless Vouch::PendingAuthentication.valid?(context, account)
      return respond_with_authentication_result(Vouch::Result.invalid(reason: :invalid_continuation), response_handler) { head :forbidden }
    end

    identity = pending_candidate_identities(account, context).detect { |candidate| Vouch::RecordKey.to_param(candidate) == params[:identity_id].to_s }
    unless identity
      return respond_with_authentication_result(Vouch::Result.invalid(reason: :invalid_selection), response_handler) { head :forbidden }
    end

    establish_membership(identity, context, &response_handler)
  end

  def destroy(&response_handler)
    identity = current_identity
    completed = run_authentication_hooks(:sign_out, identity) do |env|
      committed = run_commit_hooks(:sign_out, *env.args, **env.kwargs) do
        true
      end
      env.abort! unless committed
      Vouch.logout_scope(warden, session, auth_scope_name)
      true
    end
    result = completed ? Vouch::Result.ok(identity) : Vouch::Result.cancelled(record: identity)
    respond_with_authentication_result(result, response_handler) do
      completed ? redirect_to(after_sign_out_path) : head(:forbidden)
    end
  end

  private

  def require_unimpersonated_selection!
    Vouch::ImpersonationStack.discard_invalid!(warden: warden, session: session)
    head :forbidden if Vouch::ImpersonationStack.membership_restricted?(session)
  end

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
    redirect_to parent.route_path(:sessions, :new, self)
  end

  def complete_combined_scope(&response_handler)
    pending = authentication_session.load_selection
    unless pending
      return respond_with_authentication_result(Vouch::Result.invalid(reason: :invalid_continuation), response_handler) do
        redirect_to new_session_path
      end
    end

    identity = pending_candidate_identities(pending.account, pending.context).detect do |candidate|
      Vouch::RecordKey.to_param(candidate) == params[:identity_id].to_s
    end
    outcome = identity ? bind_identity(pending.account, identity, pending.context) : :invalid_selection
    respond_with_authentication_result(sign_in_result(pending.account, outcome), response_handler) do
      if outcome == :signed_in
        redirect_after_authentication
      else
        redirect_to new_session_path, alert: I18n.t("vouch.user_selection.invalid_selection")
      end
    end
  end

  def establish_membership(identity, context, &response_handler)
    account = current_account
    result = begin
      invitation = nil
      completed = run_authentication_hooks_with_invitation(:sign_in, account, identity,
        authentication_method: context.fetch('method').to_sym) do |env|
        committed = run_commit_hooks(:sign_in, *env.args, **env.kwargs) do
          account.lock!
          next false unless Vouch::PendingAuthentication.valid?(context, account)
          next false unless authentication_allowed?(account, context)
          next false unless pending_candidate_identities(account, context).any? { |candidate| Vouch::RecordKey.same?(candidate, identity) }

          invitation = accept_pending_invitation(account, publish: false, transactional: true)
          true
        end
        env.abort! unless committed
        renew_authentication_session
        session.delete(selection_session_key)
        if invitation
          publish_invitation_acceptance
        end
        warden.set_user(identity, scope: auth_scope_name, store: true, event: :authentication)
        true
      end
      completed ? Vouch::Result.ok(account, identity: identity) : Vouch::Result.cancelled(record: identity)
    rescue Vouch::Persistence::Cancelled => error
      Vouch::Result.cancelled(error: error, record: identity)
    end
    respond_with_authentication_result(result, response_handler) do
      result.ok? ? redirect_after_authentication : head(:forbidden)
    end
  end
end
