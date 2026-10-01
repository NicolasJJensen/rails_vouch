# frozen_string_literal: true

module Vouch
  class AuthenticationSession
    module OAuthRegistration
      def consume_oauth_initiation(auth_hash)
        nonce = controller.request.env.fetch("omniauth.params", {})[Vouch::OAuthInitiation::REQUEST_PARAM]
        contexts = session[Vouch::OAuthInitiation.contexts_key(scope)]
        context = contexts.delete(nonce) if contexts.is_a?(Hash) && nonce.is_a?(String)
        return unless context.is_a?(Hash) && context["issued_at"].is_a?(Numeric)

        age = Time.current.to_f - context["issued_at"]
        return unless age >= 0 && age < Vouch.configuration.pending_authentication_ttl.to_f
        return unless context["scope"] == scope.to_s && context["provider"] == auth_hash.provider.to_s

        context
      end

      def oauth_initiation_matches_account?(context, account)
        return false unless context && account
        return false unless context["account_scope"] == controller.send(:auth_mapping).evidence_scope_name.to_s
        return false unless Vouch::RecordKey.same?(context["account_id"], Vouch::RecordKey.serialize(account), model: account.class)
        return false unless context["fingerprint"] == Vouch::PendingAuthentication.fingerprint(account)

        ActiveSupport::SecurityUtils.secure_compare(context["context_id"].to_s, context_id)
      end

      def begin_oauth_registration!(auth_hash, account: nil, reconnect_uid: nil)
        stored = session[key(:oauth_registration)]
        if stored && !valid_oauth_registration_context?
          clear_oauth_registration
          return Vouch::Result.invalid(reason: :context_changed)
        end
        account ||= oauth_registration_account
        context = (stored || {
          "providers" => [], "attributes" => {}, "scope" => scope.to_s,
          "context_id" => context_id, "invitation" => session[key(:invited_user)]&.deep_dup,
          "account_id" => account.persisted? ? Vouch::RecordKey.serialize(account) : nil
        }).deep_dup
        providers = context.fetch("providers")
        provider_name = auth_hash.provider.to_s
        provider_uid = auth_hash.uid.to_s
        if reconnect_uid
          expected = providers.find { |entry| entry.dig("oauth", "provider") == provider_name && entry.dig("oauth", "uid") == reconnect_uid.to_s }
          return Vouch::Result.invalid(reason: :identity_mismatch) unless expected && provider_uid == reconnect_uid.to_s
        end
        existing = providers.find { |entry| entry.dig("oauth", "provider") == provider_name && entry.dig("oauth", "uid") == provider_uid }
        if existing
          existing["verified_at"] = Time.current.to_f
          existing["oauth"] = controller.send(:serialize_oauth, auth_hash)
          return store_oauth_registration(context, account)
        end
        return Vouch::Result.invalid(reason: :too_many_providers) if providers.size >= 5

        mapping = controller.send(:auth_mapping)
        identity = mapping.oauth_identity_class.build_from_omniauth(auth_hash,
          account: account, oauth_account_association: mapping.oauth_account_association)
        account.apply_oauth_registration(identity, auth_hash: auth_hash)
        account.association(mapping.oauth_identity_association.name).reset
        context["attributes"] = oauth_registration_attributes(account)
        owner = mapping.oauth_account_association
        excluded = Array(identity.class.primary_key) + Array(owner.foreign_key) +
          [owner.polymorphic? ? owner.foreign_type : nil, "provider", "uid", "auth_data", "created_at", "updated_at",
           "access_token", "refresh_token", "id_token", "token", "secret"]
        providers << {"oauth" => controller.send(:serialize_oauth, auth_hash), "verified_at" => Time.current.to_f,
          "attributes" => identity.attributes.except(*excluded.compact.map(&:to_s))}
        store_oauth_registration(context, account)
      end

      def retain_oauth_registration_attributes!(account)
        context = session[key(:oauth_registration)]
        return unless context

        candidate = context.deep_dup
        candidate["attributes"] = oauth_registration_attributes(account)
        store_oauth_registration(candidate, account)
      end

      def oauth_registration_attributes(account)
        account.attributes.slice(*account.changed_attribute_names_to_save)
          .except("password", "password_confirmation", "password_digest", *Array(account.class.primary_key))
      end

      def store_oauth_registration(context, account)
        if ActiveSupport::JSON.encode(context).bytesize > controller.send(:oauth_registration_byte_limit)
          return Vouch::Result.invalid(reason: :registration_too_large)
        end

        session[key(:oauth_registration)] = context
        Vouch::Result.ok(account)
      end

      def valid_oauth_registration_context?
        context = session[key(:oauth_registration)]
        return false unless context.is_a?(Hash) && context["scope"] == scope.to_s
        return false unless context["providers"].is_a?(Array) && context["attributes"].is_a?(Hash)
        return false unless context["invitation"] == session[key(:invited_user)]
        return false unless ActiveSupport::SecurityUtils.secure_compare(context["context_id"].to_s, context_id)
        return true unless context["account_id"]

        invitation = controller.send(:pending_invited_identity)
        account = controller.send(:invitation_account_for, invitation) if invitation
        account && Vouch::RecordKey.same?(context["account_id"], Vouch::RecordKey.serialize(account), model: account.class)
      end

      def load_oauth_registration
        return unless valid_oauth_registration_context?
        context = session[key(:oauth_registration)]
        entry = context&.fetch("providers", [])&.find { |provider| !oauth_registration_expired?(provider) }
        controller.send(:parse_oauth, entry["oauth"]) if entry
      end

      def oauth_registration_providers
        return [] unless valid_oauth_registration_context?
        context = session[key(:oauth_registration)]
        Array(context&.fetch("providers", [])).map do |entry|
          { provider: entry.dig("oauth", "provider"), uid: entry.dig("oauth", "uid"),
            expired: oauth_registration_expired?(entry) }
        end
      end

      def oauth_registration_hashes
        context = session[key(:oauth_registration)]
        Array(context&.fetch("providers", [])).map { |entry| controller.send(:parse_oauth, entry.fetch("oauth")) }
      end

      def oauth_registration_identity_attributes(oauth)
        context = session[key(:oauth_registration)]
        entry = context.fetch("providers").find do |provider|
          provider.dig("oauth", "provider") == oauth.provider.to_s && provider.dig("oauth", "uid") == oauth.uid.to_s
        end
        entry&.fetch("attributes", {}) || {}
      end

      def remove_oauth_registration_identity(provider:, uid:)
        return Vouch::Result.invalid(reason: :context_changed) unless valid_oauth_registration_context?
        context = session[key(:oauth_registration)]
        return Vouch::Result.invalid(reason: :not_found) unless context

        removed = context.fetch("providers").reject! do |entry|
          entry.dig("oauth", "provider") == provider.to_s && entry.dig("oauth", "uid") == uid.to_s
        end
        removed ? Vouch::Result.ok : Vouch::Result.invalid(reason: :not_found)
      end

      def oauth_registration_account
        invitation = controller.send(:pending_invited_identity)
        account = if invitation && controller.send(:invitation_requires_registration?, invitation)
          controller.send(:invitation_account_for, invitation)
        else
          controller.send(:auth_mapping).account_class.new
        end
        attributes = session[key(:oauth_registration)]&.fetch("attributes", {}) || {}
        account.assign_attributes(attributes)
        account
      end

      def oauth_registration_expired?(entry)
        issued_at = entry["verified_at"]
        return true unless issued_at.is_a?(Numeric)

        age = Time.current.to_f - issued_at
        age < 0 || age >= Vouch.configuration.pending_authentication_ttl.to_f
      end

      def oauth_registration_present?
        session.key?(key(:oauth_registration))
      end

      def oauth_initiation_return_to
        session[Vouch::OAuthInitiation.return_to_key(scope)]
      end

      def clear_oauth_initiation_return_to
        session.delete(Vouch::OAuthInitiation.return_to_key(scope))
      end

      def clear_oauth_registration
        session.delete(key(:oauth_registration))
      end
    end
  end
end
