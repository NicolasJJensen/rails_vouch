# frozen_string_literal: true

module Vouch
  module AuthenticationCompletion
    private

    def complete_sign_in(account, hook: :sign_in, method: :password, context: nil,
                         credential: nil, refresh_oauth: false, signed_in_via: nil,
                         evidence_method: nil, recovery_owner: nil,
                         **hook_opts, &block)
      return :denied if Vouch::ImpersonationStack.active?(session)
      if method == :registration
        session[Vouch::Session.key_for(auth_scope_name, :completion)] = "sign_up"
      end
      context ||= build_pending_authentication_context(account, hook, method, refresh_oauth, hook_opts)
      account.reload
      return :denied unless Vouch::PendingAuthentication.valid?(context, account)
      return :denied unless authentication_allowed?(account, context)

      identities = pending_candidate_identities(account, context)
      return :no_identity if identities.empty?

      if needs_second_factor?(account, context) && !credential && !context['factor'] && !evidence_method
        primary = signed_in_via ? signed_in_via_reference(signed_in_via) : self.signed_in_via
        authentication_session.begin_second_factor!(context, primary: primary)
        return :needs_two_factor
      end

      context['factor'] = credential_reference(credential) if credential
      if evidence_method
        context['evidence'] = Vouch::AuthenticationEvidence.build(method: evidence_method, account: account,
          credential: credential, owner: recovery_owner || credential)
      end
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
      candidate_identities_for(account).select { |identity| ids.include?(Vouch::RecordKey.serialize(identity)) }
    end

    def bind_identity(account, identity, context, oauth_auth_hash: nil)
      return :denied if Vouch::ImpersonationStack.active?(session)
      factor = nil
      invitation = nil
      hook = context['hook'].to_sym
      oauth = context['oauth'] && parse_oauth(context['oauth'])
      completed = run_authentication_hooks_with_invitation(hook, account, identity, **(oauth ? {auth_hash: oauth} : {})) do |env|
        committed = run_commit_hooks(hook, account, identity,
          **(oauth ? {auth_hash: oauth} : {})) do |commit_env|
          account.lock!
          # The account or factor may change while the user completes MFA or selects an identity.
          next false unless Vouch::PendingAuthentication.valid?(context, account)
          next false unless authentication_allowed?(account, context)
          next false unless pending_candidate_identities(account, context).any? { |candidate| Vouch::RecordKey.same?(candidate, identity) }
          next false unless valid_context_factor?(account, context)
          next false unless membership_mfa_context_valid?(account, identity, context)

          factor = context_credential(account, context)
          factor.lock! if factor
          if context['refresh_oauth']
            begin
              account.update_from_oauth!(oauth_auth_hash || oauth)
            rescue ActiveRecord::RecordInvalid
              raise ActiveRecord::Rollback
            end
          end
          commit_env.add(factor) if factor
          yield commit_env if block_given?
          invitation = accept_pending_invitation(account, publish: false, transactional: true)
          account.successful_login!
          true
        end
        env.abort! unless committed
        env.add(factor) if factor

        # A failed authentication operation must not publish a Warden identity.
        renew_authentication_session
        session[Vouch::Session.key_for(auth_mapping.evidence_scope_name, :evidence)] = context['evidence'] if context['evidence']
        if invitation
          publish_invitation_acceptance
        end
        warden.set_user(identity, scope: auth_scope_name, store: true, event: :authentication)
        true
      end
      return :denied unless completed

      if context.dig("evidence", "method") == "recovery_code"
        flash[:notice] = I18n.t("vouch.two_factor.recovery_code_used")
      end
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
