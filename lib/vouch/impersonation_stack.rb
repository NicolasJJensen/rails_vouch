# frozen_string_literal: true

module Vouch
  class ImpersonationStack
    SESSION_KEY = "warden.vouch.impersonation_stack"
    Context = Data.define(:mode, :operator, :target, :operator_scope, :target_scope)

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
            valid_reference.call(entry["source"]) && %w[account membership].include?(entry["mode"]) &&
            entry["contexts"].is_a?(Array) && entry["evidence"].is_a?(Hash)
        end
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
            entries(session).first.dig("source", "scope") == scope.to_s
        end
      end

      def source_scope(session)
        restricted_source(session)&.fetch("scope", nil)&.to_sym || entries(session).first&.dig("source", "scope")&.to_sym
      end

      def membership_restricted?(session)
        entries(session).last&.fetch("mode", nil) == "membership"
      end

      def retained_account(session)
        resolved = resolve(restricted_source(session))
        resolved && resolved.first.account_for(resolved.last)
      end

      def target_scope(session)
        entries(session).last&.dig("target", "scope")&.to_sym
      end

      def original(warden:, session:, scope:)
        first = entries(session).first
        reference = Array(first&.fetch("contexts", nil)).find { |context| context["scope"] == scope.to_s }
        reference ||= first&.fetch("source", nil)
        resolved = resolve(reference)
        return unless resolved

        mapping, identity = resolved
        return identity if mapping.scope_name == scope.to_sym
      end

      def original_account(session)
        resolved = resolve(entries(session).first&.fetch("source", nil))
        resolved && resolved.first.account_for(resolved.last)
      end

      def current_source(warden:, session:, scope:)
        resolve(entries(session).first&.fetch("source", nil))&.last
      end

      def restricted_operator(session, scope:)
        resolved = resolve(restricted_source(session))
        resolved&.last if resolved && resolved.first.scope_name == scope.to_sym
      end

      def authorized_identity(session, scope:, identity: nil)
        return unless resolve(entries(session).first&.fetch("source", nil))
        resolved = resolve(entries(session).last&.fetch("target", nil))
        return unless resolved
        target_mapping, target = resolved
        return target if target_mapping.scope_name == scope.to_sym
        return if membership_restricted?(session) || !identity

        mapping = mapping_for(scope)
        return unless mapping&.membership_scope? && mapping.parent_scope_name == target_mapping.scope_name
        owner = mapping.account_for(identity)
        identity if owner && owner.class == target.class && Vouch::RecordKey.same?(owner, target)
      end

      def logout_scopes(session, scope:)
        return [] unless active?(session)
        references = entries(session).flat_map { |entry| Array(entry["contexts"]) + [entry["target"], entry["source"]] }.compact
        scopes = references.flat_map do |reference|
          mapping = mapping_for(reference["scope"])
          mapping ? [mapping.scope_name, mapping.parent_scope_name].compact : []
        end.uniq
        scopes.include?(scope.to_sym) ? scopes : []
      end

      def start!(warden:, session:, source_mapping:, target_mapping:, target:, return_to: nil, source: nil)
        stack = entries(session)
        if membership_restricted?(session)
          raise Vouch::ConfigurationError, "Membership impersonation cannot enter an account" unless target_mapping.split_model?
          source = restricted_operator(session, scope: source_mapping.scope_name)
        else
          source ||= Vouch.authenticated_identity(warden, source_mapping.scope_name)
        end
        raise Vouch::ConfigurationError, "No authenticated :#{source_mapping.scope_name} operator" unless source

        entry = {
          "target" => reference_for(target_mapping, target),
          "source" => reference_for(source_mapping, source),
          "mode" => target_mapping.split_model? ? "membership" : "account",
          "return_to" => safe_return_path(return_to),
          "contexts" => active_contexts(warden),
          "evidence" => active_evidence(warden, session)
        }
        stack << entry
        write(session, stack)
        yield if block_given?
        clear_contexts!(warden, session)
        restore_contexts!(warden, entry["contexts"], accounts_only: true) if target_mapping.split_model?
        restore_evidence!(session, entry) if target_mapping.split_model?
        warden.set_user(target, scope: target_mapping.scope_name, store: true)
        target
      end

      def context(session)
        context_for(entries(session).last)
      end

      def restoration_identity(session, all: false)
        entry = all ? entries(session).first : entries(session).last
        return unless entry
        reference = Array(entry["contexts"]).find { |item| item["scope"] == entry.dig("target", "scope") }
        resolve(reference || entry["source"])&.last
      end

      def revalidate!(warden:, session:)
        return false unless session[SESSION_KEY]
        discard_invalid!(warden: warden, session: session)
        stack = entries(session)
        return true if stack.empty?
        unless resolve(stack.first["source"])
          clear_contexts!(warden, session)
          write(session, [])
          return true
        end

        invalid_index = stack.index do |entry|
          current = context_for(entry)
          !current || (block_given? && !yield(current))
        end
        return false unless invalid_index

        previous = stack.fetch(invalid_index)
        clear_contexts!(warden, session)
        write(session, stack.take(invalid_index))
        restore_contexts!(warden, previous["contexts"])
        restore_evidence!(session, previous)
        session[AuthenticationSession::CONTEXT_KEY] = SecureRandom.hex(32)
        true
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

      def context_for(entry)
        return unless entry
        source = resolve(entry["source"])
        target = resolve(entry["target"])
        return unless source && target
        Context.new(mode: entry.fetch("mode").to_sym, operator: source.last, target: target.last,
          operator_scope: source.first.scope_name, target_scope: target.first.scope_name)
      end

      def restricted_source(session)
        return unless membership_restricted?(session)
        entries(session).reverse.take_while { |entry| entry["mode"] == "membership" }.last&.fetch("source", nil)
      end

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
        return if Vouch.configuration.lockable.invalidate_sessions_on_lockout && account.respond_to?(:locked?) && account.locked?
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

      def active_evidence(warden, session)
        Vouch.each_mapping.map(&:evidence_scope_name).uniq.each_with_object({}) do |scope, evidence|
          mapping = Vouch.mapping_for(scope)
          principal = Vouch.authenticated_identity(warden, scope)
          account = if principal && mapping.split_model? && !mapping.membership_scope? && active?(session)
            retained_account(session)
          elsif principal
            mapping.account_for(principal)
          end
          key = Vouch::Session.key_for(scope, :evidence)
          proofs = Vouch::AuthenticationEvidence.current(session[key], account: account, mapping: mapping)
          if proofs.empty?
            session.delete(key)
          else
            session[key] = proofs
            evidence[key] = proofs.deep_dup
          end
          primary_key = Vouch::Session.key_for(scope, :signed_in_via)
          evidence[primary_key] = session[primary_key].deep_dup if session[primary_key]
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
        operator = resolve(stack.first["source"])
        entry = all ? stack.first : stack.last
        restored = restoration_identity(session, all: all)
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
        restored
      end

      def clear_contexts!(warden, session)
        session.delete(AuthenticationSession::CONTEXT_KEY)
        Vouch.each_mapping do |mapping|
          warden.logout(mapping.scope_name)
          %i[evidence signed_in_via].each do |purpose|
            session.delete(Vouch::Session.key_for(mapping.evidence_scope_name, purpose))
          end
        end
      end

      def safe_return_path(value)
        return unless value.is_a?(String)
        value if value.start_with?("/") && !value.start_with?("//", "/\\")
      end
    end
  end
end
