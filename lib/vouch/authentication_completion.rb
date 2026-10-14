# frozen_string_literal: true

module Vouch
  module AuthenticationCompletion
    private

    def complete_sign_in(account, hook: :sign_in, method: :password, context: nil,
                         credential: nil, refresh_oauth: false, signed_in_via: nil,
                         evidence_method: nil, recovery_owner: nil, evidence_purpose: nil,
                         **hook_opts, &block)
      return :denied if Vouch::ImpersonationStack.active?(session)
      if method == :registration
        session[Vouch::Session.key_for(auth_scope_name, :completion)] = "sign_up"
      end
      context ||= build_pending_authentication_context(account, hook, method, refresh_oauth, hook_opts)
      account.reload
      context['first_factor'] = signed_in_via_reference(signed_in_via, account: account) if signed_in_via
      return :denied unless Vouch::PendingAuthentication.valid?(context, account)
      return :denied unless authentication_allowed?(account, context)

      identities = pending_candidate_identities(account, context)
      return :no_identity if identities.empty?

      return :denied unless prepare_sign_in_approval(account, context)
      context['factor_required'] ||= needs_second_factor?(account, context)
      context['factor'] = credential_reference(credential) if credential
      if evidence_method
        proof = Vouch::AuthenticationEvidence.build(method: evidence_method, account: account,
          credential: (credential unless evidence_method.to_sym == :recovery_code), owner: recovery_owner || credential,
          purpose: evidence_purpose)
        return :denied unless Vouch::AuthenticationEvidence.valid?(proof, account: account, mapping: auth_mapping)

        context['proofs'] = Vouch::AuthenticationEvidence.record(context['proofs'], proof, account: account, mapping: auth_mapping)
      end

      unless sign_in_requirements_satisfied?(account, context)
        authentication_session.begin_second_factor!(context, primary: context['first_factor'],
          factor_required: context['factor_required'])
        return :needs_two_factor
      end

      if identities.one?
        bind_identity(account, identities.first, context, oauth_auth_hash: hook_opts[:auth_hash], &block)
      else
        primary = context['first_factor']
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
      factors = []
      proofs = []
      invitation = nil
      hook = context['hook'].to_sym
      oauth = context['oauth'] && parse_oauth(context['oauth'])
      hook_options = {authentication_method: context.fetch('method').to_sym}
      hook_options[:auth_hash] = oauth if oauth
      if context['oauth_providers']
        hook_options[:auth_hashes] = context['oauth_providers'].map { |provider| parse_oauth(provider) }
      end
      completed = run_authentication_hooks_with_invitation(hook, account, identity, **hook_options) do |env|
        committed = run_commit_hooks(hook, account, identity, **hook_options) do |commit_env|
          account.lock!
          # The account or factor may change while the user completes MFA or selects an identity.
          next false unless Vouch::PendingAuthentication.valid?(context, account)
          next false unless authentication_allowed?(account, context)
          next false unless pending_candidate_identities(account, context).any? { |candidate| Vouch::RecordKey.same?(candidate, identity) }
          proofs = pending_authentication_proofs(account, context)
          factors = proofs.filter_map { |proof| credential_for_authentication_proof(account, proof) }.uniq
          factors.each(&:lock!)
          next false unless prepare_sign_in_approval(account, context) && sign_in_requirements_satisfied?(account, context)
          if context['refresh_oauth']
            begin
              account.update_from_oauth!(oauth_auth_hash || oauth)
            rescue ActiveRecord::RecordInvalid
              raise ActiveRecord::Rollback
            end
          end
          factors.each { |factor| commit_env.add(factor) }
          yield commit_env if block_given?
          invitation = accept_pending_invitation(account, publish: false, transactional: true)
          identity.reload if invitation && Vouch::RecordKey.same?(identity, invitation) && identity.class == invitation.class
          account.successful_login!
          true
        end
        env.abort! unless committed
        factors.each { |factor| env.add(factor) }

        # A failed authentication operation must not publish a Warden identity.
        renew_authentication_session
        primary_key = Vouch::Session.key_for(auth_mapping.evidence_scope_name, :signed_in_via)
        if context['first_factor']
          session[primary_key] = context['first_factor']
        else
          session.delete(primary_key)
        end
        proofs.each { |proof| authentication_session.store_evidence!(proof, account: account) }
        if invitation
          publish_invitation_acceptance
        end
        warden.set_user(identity, scope: auth_scope_name, store: true, event: :authentication)
        record_recent_authentication(scope: auth_scope_name, method: context["method"], at: Time.at(context["issued_at"]), origin: :sign_in)
        true
      end
      return :denied unless completed

      if proofs.any? { |proof| proof["method"] == "recovery_code" }
        flash[:notice] = I18n.t("vouch.two_factor.recovery_code_used")
      end
      proofs.each do |proof|
        factor = credential_for_authentication_proof(account, proof)
        run_hooks(:two_factor_verification, account, identity, factor, evidence: proof, additional: false)
      end
      :signed_in
    rescue Vouch::Persistence::Cancelled
      :denied
    end

    def build_pending_authentication_context(account, hook, method, refresh_oauth, hook_opts)
      candidates = candidate_identities_for(account).to_a
      oauth = hook_opts[:auth_hash] && serialize_oauth(hook_opts[:auth_hash])
      context = Vouch::PendingAuthentication.build(account, identities: candidates,
        method: method, hook: hook, provider: oauth&.dig('provider'), oauth: oauth)
      if hook_opts[:auth_hashes]
        context['oauth_providers'] = hook_opts[:auth_hashes].map { |provider| serialize_oauth(provider) }
      end
      context['refresh_oauth'] = true if refresh_oauth
      context
    end
  end
end
