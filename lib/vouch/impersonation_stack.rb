# frozen_string_literal: true

module Vouch
  class ImpersonationStack
    SESSION_KEY = "warden.vouch.impersonation_stack"

    class << self
      def discard_invalid!(warden:, session:)
        stored = session[SESSION_KEY]
        return unless stored
        valid_reference = ->(reference) do
          reference.is_a?(Hash) && reference["scope"].is_a?(String) &&
            reference["key"].present? && reference["owner"].present? &&
            reference["fingerprint"].is_a?(String)
        end
        valid = stored.is_a?(Array) && stored.any? && stored.all? do |entry|
          entry.is_a?(Hash) && valid_reference.call(entry["target"]) &&
            entry["contexts"].is_a?(Array) && entry["evidence"].is_a?(Hash)
        end
        valid &&= valid_reference.call(stored.first["operator"])
        return if valid

        clear_contexts!(warden, session)
        Vouch.each_mapping do |mapping|
          session.keys.each do |key|
            session.delete(key) if Vouch::Session.state_key?(key, mapping.scope_name)
          end
        end
        session.delete(SESSION_KEY)
      end

      def active?(session, scope: nil)
        entries(session).any? do |entry|
          scope.nil? || entry.dig("target", "scope") == scope.to_s ||
            entries(session).first.dig("operator", "scope") == scope.to_s
        end
      end

      def source_scope(session)
        entries(session).first&.dig("operator", "scope")&.to_sym
      end

      def target_scope(session)
        entries(session).last&.dig("target", "scope")&.to_sym
      end

      def original(warden:, session:, scope:)
        reference = entries(session).first&.fetch("operator", nil)
        resolved = resolve(reference)
        return unless resolved

        mapping, identity = resolved
        return identity if mapping.scope_name == scope.to_sym
        return mapping.account_for(identity) if mapping.membership_scope? && mapping.parent_scope_name == scope.to_sym
      end

      def original_account(session)
        resolved = resolve(entries(session).first&.fetch("operator", nil))
        resolved && resolved.first.account_for(resolved.last)
      end

      def current_source(warden:, session:, scope:)
        original(warden: warden, session: session, scope: scope)
      end

      # An impersonation authorizes one exact target. It never authenticates
      # that target's credentials owner or lends it the operator's MFA proof.
      def authorized_identity(session, scope:)
        return unless resolve(entries(session).first&.fetch("operator", nil))
        resolved = resolve(entries(session).last&.fetch("target", nil))
        resolved&.last if resolved && resolved.first.scope_name == scope.to_sym
      end

      def logout_scopes(session, scope:)
        return [] unless active?(session)
        references = entries(session).flat_map { |entry| Array(entry["contexts"]) + [entry["target"], entry["operator"]] }.compact
        scopes = references.flat_map do |reference|
          mapping = mapping_for(reference["scope"])
          mapping ? [mapping.scope_name, mapping.parent_scope_name].compact : []
        end.uniq
        scopes.include?(scope.to_sym) ? scopes : []
      end

      def start!(warden:, session:, source_mapping:, target_mapping:, target:, return_to: nil, source: nil)
        stack = entries(session)
        if stack.any?
          source = original(warden: warden, session: session, scope: source_mapping.scope_name)
        else
          source ||= Vouch.authenticated_identity(warden, source_mapping.scope_name)
        end
        raise Vouch::ConfigurationError, "No authenticated :#{source_mapping.scope_name} operator" unless source

        entry = {
          "target" => reference_for(target_mapping, target),
          "return_to" => safe_return_path(return_to),
          "contexts" => active_contexts(warden),
          "evidence" => active_evidence(session)
        }
        entry["operator"] = reference_for(source_mapping, source) if stack.empty?
        stack << entry
        write(session, stack)
        yield if block_given?
        clear_contexts!(warden, session)
        # Keep existing credentials scopes authenticated as the operator.
        restore_contexts!(warden, stack.first["contexts"], accounts_only: true) if target_mapping.split_model?
        restore_evidence!(session, stack.first) if target_mapping.split_model?
        warden.set_user(target, scope: target_mapping.scope_name, store: true)
        target
      end

      def stop!(warden:, session:, target_mapping:)
        restore_previous!(warden, session, all: false)
      end

      def stop_all!(warden:, session:, target_mapping:)
        restore_previous!(warden, session, all: true)
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
        stack.empty? ? session.delete(SESSION_KEY) : session[SESSION_KEY] = stack
      end

      def reference_for(mapping, identity)
        account = mapping.account_for(identity)
        tenant = mapping.tenant? ? identity.public_send(mapping.identity_tenant_association.name) : nil
        {
          "scope" => mapping.scope_name.to_s,
          "key" => Vouch::RecordKey.serialize(identity),
          "owner" => Vouch::RecordKey.serialize(account),
          "tenant" => tenant && Vouch::RecordKey.serialize(tenant),
          "fingerprint" => Vouch::PendingAuthentication.fingerprint(account)
        }
      end

      def resolve(reference)
        return unless reference.is_a?(Hash)
        mapping = mapping_for(reference["scope"])
        return unless mapping
        identity = Vouch::RecordKey.find(mapping.identity_class, reference.fetch("key"))
        account = mapping.account_for(identity)
        return unless account
        return if account.respond_to?(:locked?) && account.locked?
        return unless reference_for(mapping, identity) == reference

        [mapping, identity]
      rescue ActiveRecord::RecordNotFound, KeyError, ArgumentError, Vouch::ConfigurationError
        nil
      end

      def active_contexts(warden)
        Vouch.each_mapping.filter_map do |mapping|
          identity = Vouch.authenticated_identity(warden, mapping.scope_name)
          reference_for(mapping, identity) if identity
        end
      end

      def active_evidence(session)
        Vouch.each_mapping.each_with_object({}) do |mapping, evidence|
          key = Vouch::Session.key_for(mapping.evidence_scope_name, :evidence)
          evidence[key] = session[key].deep_dup if session[key]
        end
      end

      def restore_contexts!(warden, references, accounts_only: false)
        Array(references).each do |reference|
          resolved = resolve(reference)
          next unless resolved
          mapping, identity = resolved
          next if accounts_only && mapping.split_model?
          warden.set_user(identity, scope: mapping.scope_name, store: true)
        end
      end

      def restore_evidence!(session, entry)
        entry.fetch("evidence", {}).each { |key, value| session[key] = value.deep_dup }
      end

      def restore_previous!(warden, session, all:)
        stack = entries(session)
        return if stack.empty?
        operator = resolve(stack.first["operator"])
        entry = all ? stack.first : stack.last
        clear_contexts!(warden, session)
        unless operator
          write(session, [])
          return
        end
        all ? stack.clear : stack.pop
        write(session, stack)
        # Never fall back to ordinary login when a retained target was revoked
        # or reassigned while a deeper impersonation was active.
        if stack.any? && !authorized_identity(session, scope: target_scope(session))
          return restore_previous!(warden, session, all: true)
        end
        restore_contexts!(warden, entry["contexts"])
        restore_evidence!(session, entry)
        operator.last
      end

      def clear_contexts!(warden, session)
        Vouch.each_mapping do |mapping|
          warden.logout(mapping.scope_name)
          session.delete(Vouch::Session.key_for(mapping.evidence_scope_name, :evidence))
        end
      end

      def safe_return_path(value)
        return unless value.is_a?(String)
        value if value.start_with?("/") && !value.start_with?("//", "/\\")
      end
    end
  end
end
