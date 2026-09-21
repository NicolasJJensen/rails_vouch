# frozen_string_literal: true

module Vouch
  module AuthenticationCompletion
    private

    def complete_sign_in(account, hook: :sign_in, method: :password, context: nil,
                         credential: nil, refresh_oauth: false, signed_in_via: nil,
                         **hook_opts, &block)
      context ||= build_pending_authentication_context(account, hook, method, refresh_oauth, hook_opts)
      account.reload
      return :denied unless Vouch::PendingAuthentication.valid?(context, account)
      return :denied unless authentication_allowed?(account, context)

      identities = pending_candidate_identities(account, context)
      return :no_identity if identities.empty?

      if needs_second_factor?(account, context) && !credential && !context['factor']
        primary = signed_in_via ? signed_in_via_reference(signed_in_via) : self.signed_in_via
        authentication_session.begin_second_factor!(context, primary: primary)
        return :needs_two_factor
      end

      context['factor'] = credential_reference(credential) if credential
      return :denied unless valid_context_factor?(account, context)

      if identities.one?
        bind_identity(account, identities.first, context, oauth_auth_hash: hook_opts[:auth_hash], &block)
      else
        primary = signed_in_via ? signed_in_via_reference(signed_in_via) : self.signed_in_via
        authentication_session.begin_selection!(account, context, primary: primary)
        :needs_selection
      end
    end

    def pending_candidate_identities(account, context)
      ids = context['identity_ids'].to_set
      candidate_identities_for(account).select { |identity| ids.include?(identity.id.to_s) }
    end

    def bind_identity(account, identity, context, oauth_auth_hash: nil)
      factor = nil
      invitation = nil
      hook_execution = nil
      completed = account.with_lock(requires_new: true) do
        # The account or factor may change while the user completes MFA or selects an identity.
        next false unless Vouch::PendingAuthentication.valid?(context, account)
        next false unless authentication_allowed?(account, context)
        next false unless pending_candidate_identities(account, context).any? { |candidate| candidate.id == identity.id }
        next false unless valid_context_factor?(account, context)

        factor = context_credential(account, context)
        factor.lock! if factor
        oauth = context['oauth'] && parse_oauth(context['oauth'])
        hook_execution = prepare_lifecycle_hooks(context['hook'].to_sym, account, identity,
          **(oauth ? {auth_hash: oauth} : {}))
        operation_completed = false
        run_lifecycle_operation(hook_execution) do |env|
          next false unless valid_context_factor?(account, context)

          if context['refresh_oauth']
            begin
              account.update_from_oauth!(oauth_auth_hash || oauth)
            rescue ActiveRecord::RecordInvalid
              raise ActiveRecord::Rollback
            end
          end
          env.add(factor) if factor
          yield env if block_given?
          invitation = accept_pending_invitation(account, publish: false)
          account.successful_login!
          operation_completed = true
        end
        operation_completed
      end
      return :denied unless completed

      # A failed authentication operation must not publish a Warden identity.
      reset_session_with_preserved_keys
      publish_invitation_acceptance(account, invitation) if invitation
      warden.set_user(identity, scope: auth_scope_name, store: true, event: :authentication)
      finish_lifecycle_hooks(hook_execution, completed: completed)
      run_hooks(:two_factor_verification, account, identity, factor) if factor
      :signed_in
    rescue Vouch::Persistence::Cancelled
      :denied
    end

    def build_pending_authentication_context(account, hook, method, refresh_oauth, hook_opts)
      candidates = candidate_identities_for(account).to_a
      oauth = hook_opts[:auth_hash] && serialize_oauth(hook_opts[:auth_hash])
      context = Vouch::PendingAuthentication.build(account, identities: candidates,
        method: method, hook: hook, provider: oauth&.dig('provider'), oauth: oauth)
      context['refresh_oauth'] = true if refresh_oauth
      context
    end
  end
end
