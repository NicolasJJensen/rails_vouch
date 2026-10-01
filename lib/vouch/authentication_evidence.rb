# frozen_string_literal: true

# Current MFA proofs are separate from the Warden identity. Recovery proof
# does not claim that the lost authenticator was used.
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
        result["credential_enabled_at"] = credential.try(:two_factor_enabled_at)&.utc&.iso8601(6)
      end
      if owner
        result["owner_type"] = owner.class.name
        result["owner_id"] = Vouch::RecordKey.serialize(owner)
      end
      result
    end

    def current(entries, account:, mapping:)
      return [] unless account && entries.is_a?(Array)

      entries.select { |proof| valid?(proof, account: account, mapping: mapping) }
    end

    def record(entries, proof, account:, mapping:)
      proofs = current(entries, account: account, mapping: mapping)
      return proofs unless valid?(proof, account: account, mapping: mapping)

      proofs.reject { |existing| proof_key(existing) == proof_key(proof) } + [proof]
    end

    def valid?(proof, account:, mapping:)
      return false unless account && proof.is_a?(Hash)
      return false unless %w[two_factor recovery_code].include?(proof["method"])
      return false unless proof["account_fingerprint"] == Vouch::PendingAuthentication.fingerprint(account)
      return false if Time.iso8601(proof["verified_at"].to_s) > Time.current

      if proof["method"] == "two_factor"
        current_credential?(proof, account, mapping)
      elsif proof["owner_type"] == account.class.name
        proof["owner_id"] == Vouch::RecordKey.serialize(account)
      else
        credential_associations(mapping).any? do |association|
          account.public_send(association.name).reload.any? do |owner|
            owner.class.name == proof["owner_type"] && Vouch::RecordKey.serialize(owner) == proof["owner_id"]
          end
        end
      end
    rescue ArgumentError
      false
    end

    def proof_key(proof)
      if proof["method"] == "two_factor"
        proof.values_at("method", "credential_type", "credential_id")
      else
        proof.values_at("method", "owner_type", "owner_id")
      end
    end

    def credential_associations(mapping)
      mapping = Vouch.mapping_for(mapping.parent_scope_name) if mapping.membership_scope?
      Array(mapping.two_factor_credential_associations)
    end

    def current_credential?(evidence, account, mapping)
      return false unless account
      type = evidence["credential_type"]
      id = evidence["credential_id"]
      credential_associations(mapping).any? do |association|
        credential = account.public_send(association.name).reload.detect do |candidate|
          candidate.class.name == type && Vouch::RecordKey.serialize(candidate) == id
        end
        credential && credential.two_factor_enabled? && credential.verified? && !credential.two_factor_locked? &&
          credential.try(:verification_version) == evidence["credential_version"] &&
          credential.try(:authentication_method).to_s == evidence["credential_method"].to_s &&
          credential.verified_at&.utc&.iso8601(6) == evidence["credential_verified_at"] &&
          credential.two_factor_enabled_at&.utc&.iso8601(6) == evidence["credential_enabled_at"]
      end
    end
  end
end
