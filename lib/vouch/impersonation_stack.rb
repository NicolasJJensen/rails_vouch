# frozen_string_literal: true

module Vouch
  # Stores the authentication context that existed before impersonation. The
  # stack is deliberately made of records and authentication fingerprints, not
  # live objects, so restored sessions are revoked when the original account's
  # credentials change.
  class ImpersonationStack
    SESSION_KEY = "warden.vouch.impersonation_stack"

    class << self
      def active?(session, scope: nil)
        entries(session).any? do |entry|
          scope.nil? || entry["target_scope"] == scope.to_s || entry["source_scope"] == scope.to_s
        end
      end

      def original(warden:, session:, scope:)
        original_for_entry(entries(session).first, scope)
      rescue ArgumentError, Vouch::ConfigurationError
        nil
      end

      # The source of the current impersonation level. Termination uses this
      # rather than the bottom-of-stack actor, so a cross-scope nested target
      # restores one level instead of stopping the full stack.
      def current_source(warden:, session:, scope:)
        original_for_entry(entries(session).last, scope)
      rescue ArgumentError, Vouch::ConfigurationError
        nil
      end

      # Every session scope touched by an active impersonation stack. Used by
      # logout to prevent a stale target or original context surviving a
      # deliberate sign-out.
      def logout_scopes(session, scope:)
        requested = scope.to_sym
        relevant = entries(session).select do |entry|
          source = mapping_for(entry["source_scope"])
          target = mapping_for(entry["target_scope"])
          next false unless source && target

          [source.scope_name, source.parent_scope_name, target.scope_name, target.parent_scope_name].compact.include?(requested)
        end
        return [] if relevant.empty?

        entries(session).flat_map do |entry|
          [mapping_for(entry["source_scope"]), mapping_for(entry["target_scope"])]
        end.compact.flat_map { |mapping| [mapping.scope_name, mapping.parent_scope_name].compact }.uniq
      end

      def start!(warden:, session:, source_mapping:, target_mapping:, target:, return_to: nil, source: nil)
        source ||= Vouch.authenticated_identity(warden, source_mapping.scope_name)
        raise Vouch::ConfigurationError, "No authenticated :#{source_mapping.scope_name} identity to impersonate from" unless source

        stack = entries(session)
        stack << entry_for(warden, session, source_mapping, source, target_mapping, return_to)
        write(session, stack)
        yield if block_given?
        clear_active_contexts!(warden, session)
        publish!(warden, target_mapping, target)
        target
      end

      def stop!(warden:, session:, target_mapping:)
        stack = entries(session)
        entry = stack.pop
        write(session, stack)
        return nil unless entry

        restore!(warden, session, target_mapping, entry)
      end

      def stop_all!(warden:, session:, target_mapping:)
        stack = entries(session)
        entry = stack.first
        stack.each do |pending|
          mapping = Vouch.mapping_for(pending.fetch("target_scope"))
          clear_mapping!(warden, mapping)
          session.delete(Vouch::Session.key_for(mapping.evidence_scope_name, :evidence))
        rescue ArgumentError, Vouch::ConfigurationError, KeyError
          next
        end
        clear(session)
        return nil unless entry

        restore!(warden, session, target_mapping, entry)
      end

      def return_to(session)
        safe_return_path(entries(session).last&.fetch("return_to", nil))
      end

      private

      def mapping_for(scope)
        Vouch.mapping_for(scope)
      rescue ArgumentError, Vouch::ConfigurationError
        nil
      end

      def entries(session)
        value = session[SESSION_KEY]
        value.is_a?(Array) ? value.select { |entry| entry.is_a?(Hash) } : []
      end

      def write(session, stack)
        stack.empty? ? clear(session) : session[SESSION_KEY] = stack
      end

      def clear(session)
        session.delete(SESSION_KEY)
      end

      def entry_for(warden, session, source_mapping, source, target_mapping, return_to)
        account = source_mapping.account_for(source)
        {
          "source_scope" => source_mapping.scope_name.to_s,
          "source_id" => Vouch::RecordKey.serialize(source),
          "source_fingerprint" => Vouch::PendingAuthentication.fingerprint(account),
          "target_scope" => target_mapping.scope_name.to_s,
          "return_to" => safe_return_path(return_to),
          "contexts" => active_contexts(warden),
          "evidence" => active_evidence(session, warden)
        }
      end

      def restore!(warden, session, target_mapping, entry)
        source = restoreable_identity(entry)
        clear_mapping!(warden, target_mapping)
        session.delete(Vouch::Session.key_for(target_mapping.evidence_scope_name, :evidence))
        return nil unless source

        contexts = restoreable_contexts(entry)
        if contexts.empty?
          source_mapping = Vouch.mapping_for(entry.fetch("source_scope"))
          publish!(warden, source_mapping, source)
        else
          contexts.each { |mapping, identity| publish!(warden, mapping, identity) }
        end
        restore_evidence!(session, entry, contexts)
        source
      rescue ArgumentError, Vouch::ConfigurationError
        nil
      end

      def restoreable_identity(entry)
        mapping = Vouch.mapping_for(entry.fetch("source_scope"))
        identity = Vouch::RecordKey.find(mapping.identity_class, entry.fetch("source_id"))
        account = mapping.account_for(identity)
        return nil unless account
        return nil if account.respond_to?(:locked?) && account.locked?

        fingerprint = Vouch::PendingAuthentication.fingerprint(account)
        return nil unless ActiveSupport::SecurityUtils.secure_compare(
          entry.fetch("source_fingerprint").to_s, fingerprint.to_s
        )

        identity
      rescue ActiveRecord::RecordNotFound, KeyError, ArgumentError
        nil
      end

      def original_for_entry(entry, scope)
        return nil unless entry

        mapping = Vouch.mapping_for(entry["source_scope"])
        identity = restoreable_identity(entry)
        return nil unless identity
        return identity if entry["source_scope"] == scope.to_s
        return mapping.account_for(identity) if mapping.membership_scope? && mapping.parent_scope_name == scope.to_sym

        nil
      end

      def active_contexts(warden)
        Vouch.each_mapping.filter_map do |mapping|
          identity = Vouch.authenticated_identity(warden, mapping.scope_name)
          next unless identity

          account = mapping.account_for(identity)
          {
            "scope" => mapping.scope_name.to_s,
            "id" => Vouch::RecordKey.serialize(identity),
            "fingerprint" => Vouch::PendingAuthentication.fingerprint(account)
          }
        end
      end

      def restoreable_contexts(entry)
        Array(entry["contexts"]).filter_map do |context|
          mapping = mapping_for(context["scope"])
          next unless mapping

          identity = Vouch::RecordKey.find(mapping.identity_class, context["id"])
          account = mapping.account_for(identity)
          next unless account
          next if account.respond_to?(:locked?) && account.locked?
          next unless ActiveSupport::SecurityUtils.secure_compare(
            context["fingerprint"].to_s, Vouch::PendingAuthentication.fingerprint(account).to_s
          )

          [mapping, identity]
        rescue ActiveRecord::RecordNotFound, ArgumentError, KeyError
          nil
        end
      end

      def active_evidence(session, warden)
        active_contexts(warden).each_with_object({}) do |context, evidence|
          mapping = mapping_for(context["scope"])
          next unless mapping

          key = Vouch::Session.key_for(mapping.evidence_scope_name, :evidence)
          evidence[key] = session[key].deep_dup if session[key]
        end
      end

      def restore_evidence!(session, entry, contexts)
        permitted_keys = contexts.map do |mapping, _identity|
          Vouch::Session.key_for(mapping.evidence_scope_name, :evidence)
        end
        if permitted_keys.empty?
          mapping = mapping_for(entry["source_scope"])
          permitted_keys << Vouch::Session.key_for(mapping.evidence_scope_name, :evidence) if mapping
        end
        entry.fetch("evidence", {}).each do |key, evidence|
          session[key] = evidence.deep_dup if permitted_keys.include?(key)
        end
      end

      def clear_active_contexts!(warden, session)
        Vouch.each_mapping do |mapping|
          clear_mapping!(warden, mapping)
          session.delete(Vouch::Session.key_for(mapping.evidence_scope_name, :evidence))
        end
      end

      def clear_mapping!(warden, mapping)
        scopes = [mapping.scope_name]
        scopes << mapping.parent_scope_name if mapping.membership_scope?
        warden.logout(*scopes.compact)
      end

      def publish!(warden, mapping, identity)
        if mapping.membership_scope?
          warden.set_user(mapping.account_for(identity), scope: mapping.parent_scope_name, store: true)
        end
        warden.set_user(identity, scope: mapping.scope_name, store: true)
      end

      def safe_return_path(value)
        return nil unless value.is_a?(String)
        return nil unless value.start_with?("/") && !value.start_with?("//", "/\\")

        value
      end
    end
  end
end
