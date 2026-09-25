# frozen_string_literal: true

# The proof that completed the latest MFA challenge. It is deliberately kept
# separate from the Warden identity: a recovery code is valid account proof,
# but it is not proof that an authenticator was used.
module Vouch
  module AuthenticationEvidence
    module_function

    def build(method:, account: nil, credential: nil, owner: nil, verified_at: Time.current)
      result = {"method" => method.to_s, "verified_at" => verified_at.utc.iso8601(6)}
      result["account_fingerprint"] = Vouch::PendingAuthentication.fingerprint(account) if account
      if credential
        result["credential_type"] = credential.class.name
        result["credential_method"] = credential.respond_to?(:authentication_method) ? credential.authentication_method.to_s : credential.class.name
        result["credential_id"] = Vouch::RecordKey.serialize(credential)
        result["credential_version"] = credential.try(:verification_version)
        result["credential_verified_at"] = credential.try(:verified_at)&.utc&.iso8601(6)
      end
      if owner
        result["owner_type"] = owner.class.name
        result["owner_id"] = Vouch::RecordKey.serialize(owner)
      end
      result
    end

    def qualifies?(evidence, requirements, account: nil, mapping: nil)
      return true if requirements.blank?
      return false unless evidence.is_a?(Hash)
      return false unless %w[two_factor recovery_code].include?(evidence["method"])
      return false if account && !ActiveSupport::SecurityUtils.secure_compare(
        evidence["account_fingerprint"].to_s, Vouch::PendingAuthentication.fingerprint(account))
      return false if mapping && evidence["method"] == "two_factor" && !current_credential?(evidence, account, mapping)
      requirements = requirements.stringify_keys
      timestamp = Time.iso8601(evidence["verified_at"].to_s)
      return false if timestamp > Time.current
      return false if evidence["method"] == "recovery_code" && requirements["allow_recovery_codes"] != true

      # A policy must explicitly permit recovery-code proof. When permitted,
      # it can stand in for a listed factor type because it is intentionally
      # a recovery path rather than proof that that device was used.
      unless evidence["method"] == "recovery_code"
        types = Array(requirements["credential_types"]).compact.map { |type| type.respond_to?(:name) ? type.name : type.to_s }
        return false if types.any? && !types.include?(evidence["credential_type"].to_s)
        methods = Array(requirements["credential_methods"]).compact.map(&:to_s)
        return false if methods.any? && !methods.include?(evidence["credential_method"].to_s)
      end

      max_age = requirements["max_age"]
      return true unless max_age
      return false if max_age.to_f.negative?
      timestamp >= Time.current - max_age.to_f
    rescue ArgumentError
      false
    end

    def membership_valid?(session, mapping, identity, policy:, controller:)
      return true unless policy.respond_to?(:membership_mfa_requirements)

      account = mapping.account_for(identity)
      tenant = mapping.tenant? ? identity.public_send(mapping.identity_tenant_association.name) : nil
      requirements = policy.membership_mfa_requirements(account, identity: identity, tenant: tenant, controller: controller)
      evidence = session[Vouch::Session.key_for(mapping.parent_scope_name, :evidence)]
      qualifies?(evidence, requirements, account: account, mapping: mapping)
    end

    def current_credential?(evidence, account, mapping)
      return false unless account
      type = evidence["credential_type"]
      id = evidence["credential_id"]
      credential_mapping = if mapping.membership_scope?
        Vouch.mapping_for(mapping.parent_scope_name)
      else
        mapping
      end
      Array(credential_mapping.two_factor_credential_associations).any? do |association|
        credential = account.public_send(association.name).detect do |candidate|
          candidate.class.name == type && Vouch::RecordKey.serialize(candidate) == id
        end
        credential && credential.two_factor_enabled? && credential.verified? && !credential.two_factor_locked? &&
          credential.try(:verification_version) == evidence["credential_version"] &&
          credential.try(:authentication_method).to_s == evidence["credential_method"].to_s &&
          credential.verified_at&.utc&.iso8601(6) == evidence["credential_verified_at"]
      end
    end
  end
end
