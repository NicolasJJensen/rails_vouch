# frozen_string_literal: true

module Vouch
  module SignInApproval
    private

    def prepare_sign_in_approval(account, context)
      return valid_sign_in_approval?(account, context) if context.key?("sign_in_approval")

      policy = authentication_policy
      options = approval_policy_options(context)
      required = policy.respond_to?(:sign_in_approval_required?) && policy.sign_in_approval_required?(account, **options)
      context["sign_in_approval"] = false
      return true unless required

      context["sign_in_approval"] = {}
      selected = policy.sign_in_approval_credential(account, **options)
      return false unless selected

      credential = approval_credentials_for(account, context).detect do |candidate|
        candidate.class == selected.class && Vouch::RecordKey.same?(candidate, selected)
      end
      return false unless credential && approval_credential_usable?(credential)

      context["sign_in_approval"] = approval_credential_reference(credential)
      true
    end

    def approval_policy_options(context)
      { method: context.fetch("method").to_sym, provider: context["provider"], controller: self }
    end

    def approval_credentials_for(account, context)
      primary = context["first_factor"]
      two_factor_credentials_for(account, exclude_primary: false).reject do |credential|
        primary && primary["type"] == credential.class.name && primary["id"] == Vouch::RecordKey.serialize(credential)
      end
    end

    def approval_credential_usable?(credential)
      credential.persisted? && credential.respond_to?(:verified?) && credential.verified? && !credential.two_factor_locked? &&
        credential.respond_to?(:sign_in_approval_challenge)
    end

    def approval_credential_reference(credential)
      credential_reference(credential).except("used_at")
    end

    def sign_in_approval_credential(account, context)
      reference = context["sign_in_approval"]
      return unless reference.is_a?(Hash)

      approval_credentials_for(account, context).detect do |credential|
        approval_credential_usable?(credential) && approval_credential_reference(credential) == reference
      end
    end

    def valid_sign_in_approval?(account, context)
      !context["sign_in_approval"] || sign_in_approval_credential(account, context).present?
    end

    def sign_in_approval_satisfied?(account, context)
      return true unless context["sign_in_approval"]

      credential = sign_in_approval_credential(account, context)
      return false unless credential

      policy = authentication_policy
      policy = Vouch::AuthenticationPolicy.new unless policy.respond_to?(:sign_in_approval_satisfied?)
      pending_authentication_proofs(account, context).any? do |proof|
        policy.sign_in_approval_satisfied?(account, credential: credential, evidence: proof, **approval_policy_options(context))
      end
    end

    def credential_for_authentication_proof(account, proof)
      return unless proof["method"] == "two_factor"

      two_factor_credentials_for(account, exclude_primary: false).detect do |credential|
        proof["credential_type"] == credential.class.name && proof["credential_id"] == Vouch::RecordKey.serialize(credential)
      end
    end

    def pending_authentication_proofs(account, context)
      Vouch::AuthenticationEvidence.current(context["proofs"] || Array.wrap(context["evidence"]),
        account: account, mapping: auth_mapping)
    end

    def sign_in_requirements_satisfied?(account, context)
      valid_context_factor?(account, context) && sign_in_approval_satisfied?(account, context)
    end
  end
end
