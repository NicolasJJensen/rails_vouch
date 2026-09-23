require 'digest'

module Vouch
  class PendingAuthentication
    def self.fingerprint(account)
      version = account.respond_to?(:auth_session_version) ? account.auth_session_version : nil
      Digest::SHA256.hexdigest([account.class.name, Vouch::RecordKey.dump(account), account.try(:created_at)&.utc&.iso8601(6),
        account.try(:password_digest), version].to_json)
    end

    def self.build(account, identities:, method:, hook:, provider: nil, oauth: nil)
      {
        'account_id' => Vouch::RecordKey.serialize(account),
        'fingerprint' => fingerprint(account),
        'issued_at' => Time.current.to_f,
        'identity_ids' => identities.map { |identity| Vouch::RecordKey.serialize(identity) },
        'method' => method.to_s,
        'hook' => hook.to_s,
        'provider' => provider,
        'oauth' => oauth
      }
    end

    def self.valid?(context, account)
      return false unless context.is_a?(Hash) && account
      return false unless Vouch::RecordKey.same?(context['account_id'], Vouch::RecordKey.serialize(account), model: account.class)
      return false unless context['issued_at'].is_a?(Numeric)
      return false unless context['identity_ids'].is_a?(Array)
      return false unless %w[sign_in oauth_sign_in].include?(context['hook'])

      age = Time.current.to_f - context['issued_at']
      age >= 0 && age < Vouch.configuration.pending_authentication_ttl.to_f &&
        ActiveSupport::SecurityUtils.secure_compare(context['fingerprint'].to_s, fingerprint(account))
    end
  end
end
