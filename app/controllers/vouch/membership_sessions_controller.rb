# frozen_string_literal: true

class Vouch::MembershipSessionsController < ::ApplicationController
  include Vouch::Authentication
  skip_before_action :validate_impersonation_context, only: :destroy

  allow_unauthenticated_access
  before_action :require_unimpersonated_selection!, only: %i[new create]
  before_action :require_account_session!

  def new
    return if performed?

    unless auth_mapping.membership_scope?
      pending = authentication_session.load_selection
      return set_operation_result(Vouch::Result.invalid(reason: :invalid_continuation)) unless pending

      @vouch_account = pending.account
      @vouch_identities = pending_candidate_identities(@vouch_account, pending.context)
      expose_authentication_records
      return
    end
    @vouch_account = current_account
    @vouch_identities = candidate_identities_for(@vouch_account).to_a
    return set_operation_result(Vouch::Result.invalid(reason: :no_identity)) if @vouch_identities.empty?

    context = Vouch::PendingAuthentication.build(@vouch_account, identities: @vouch_identities,
      method: :session, hook: :sign_in)
    return set_operation_result(Vouch::Result.invalid(reason: :denied)) unless authentication_allowed?(@vouch_account, context)

    session[selection_session_key] = context
    if @vouch_identities.one?
      establish_membership(@vouch_identities.first, context)
    else
      expose_authentication_records
      nil
    end
  end

  def create
    return if performed?

    return complete_combined_scope unless auth_mapping.membership_scope?

    context = session[selection_session_key]
    @vouch_account = current_account
    unless Vouch::PendingAuthentication.valid?(context, @vouch_account)
      return set_operation_result(Vouch::Result.invalid(reason: :invalid_continuation))
    end

    identity = pending_candidate_identities(@vouch_account, context).detect { |candidate| Vouch::RecordKey.to_param(candidate) == params[:identity_id].to_s }
    unless identity
      return set_operation_result(Vouch::Result.invalid(reason: :invalid_selection))
    end

    establish_membership(identity, context)
  end

  def destroy
    return if performed?

    identity = current_identity
    @vouch_account = current_account
    completed = run_authentication_hooks(:sign_out, identity) do |env|
      committed = run_commit_hooks(:sign_out, *env.args, **env.kwargs) do
        true
      end
      env.abort! unless committed
      Vouch.logout_scope(warden, session, auth_scope_name)
      true
    end
    result = completed ? Vouch::Result.ok(identity) : Vouch::Result.cancelled(record: identity)
    @vouch_identity = identity
    set_operation_result(result)
  end

  private

  def default_render
    return if performed?
    return super unless @_vouch_operation_result

    case action_name
    when "new", "create"
      if @operation_status == :ok
        redirect_after_authentication
      elsif auth_mapping.membership_scope?
        head :forbidden
      elsif @failure_reason == :invalid_continuation
        redirect_to new_session_path
      else
        redirect_to new_session_path, alert: I18n.t("vouch.user_selection.invalid_selection")
      end
    when "destroy"
      @operation_status == :ok ? redirect_to(after_sign_out_path) : head(:forbidden)
    else
      super
    end
  end

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

  def complete_combined_scope
    pending = authentication_session.load_selection
    unless pending
      return set_operation_result(Vouch::Result.invalid(reason: :invalid_continuation))
    end

    @vouch_account = pending.account
    @vouch_identity = pending_candidate_identities(@vouch_account, pending.context).detect do |candidate|
      Vouch::RecordKey.to_param(candidate) == params[:identity_id].to_s
    end
    outcome = @vouch_identity ? bind_identity(@vouch_account, @vouch_identity, pending.context) : :invalid_selection
    set_operation_result(sign_in_result(@vouch_account, outcome))
  end

  def establish_membership(identity, context)
    @vouch_identity = identity
    @vouch_account = account = current_account
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
        original_proof = recent_sign_in_proof(auth_mapping.parent_scope_name)
        renew_authentication_session
        session.delete(selection_session_key)
        if invitation
          publish_invitation_acceptance
        end
        warden.set_user(identity, scope: auth_scope_name, store: true, event: :authentication)
        if original_proof
          [auth_scope_name, auth_mapping.parent_scope_name].each do |scope|
            record_recent_authentication(scope: scope, method: original_proof.fetch("method"),
              at: Time.iso8601(original_proof.fetch("verified_at")), origin: :sign_in)
          end
        end
        true
      end
      completed ? Vouch::Result.ok(account, identity: identity) : Vouch::Result.cancelled(record: identity)
    rescue Vouch::Persistence::Cancelled => error
      Vouch::Result.cancelled(error: error, record: identity)
    end
    set_operation_result(result)
  end
end
