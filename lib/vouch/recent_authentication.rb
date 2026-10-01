# frozen_string_literal: true

module Vouch
  module RecentAuthentication
    extend ActiveSupport::Concern

    class_methods do
      def require_recent_authentication(scope: nil, within: 10.minutes, **options)
        raise ArgumentError, "within must be a positive duration" unless within.to_f.positive?

        before_action(**options) do
          selected_scope = scope || (auth_scope_name if respond_to?(:auth_scope_name, true))
          unless selected_scope
            scopes = Vouch.mappings.values.reject(&:membership_scope?)
            raise Vouch::ConfigurationError, "Specify scope: when more than one credentials scope exists" unless scopes.one?
            selected_scope = scopes.first.scope_name
          end
          ensure_recent_authentication!(scope: selected_scope, within: within)
        end
      end
    end

    def recent_authentication?(scope:, within: 10.minutes)
      context = recent_authentication_context(scope)
      return false unless context

      confirmation = session[Vouch::Session.key_for(scope, :confirmation)]
      if confirmation.is_a?(Hash) && confirmation["context"] == context
        return true if recent_authentication_proof?(confirmation["proof"], within: within)
      end
      return false if Vouch::ImpersonationStack.active?(session)

      authentication_evidence(scope: scope).any? { |proof| recent_authentication_proof?(proof, within: within) }
    end

    private

    def ensure_recent_authentication!(scope:, within:)
      return if is_a?(Vouch::SessionsController) && %w[confirmation confirm cancel_confirmation].include?(action_name)
      return if is_a?(Vouch::TwoFactorChallengeController)
      return if performed? || recent_authentication?(scope: scope, within: within)
      mapping = Vouch.mapping_for(scope)
      unless recent_authentication_context(scope)
        return redirect_to mapping.route_path(:sessions, :new, self)
      end

      key = Vouch::Session.key_for(scope, :confirmation_pending)
      pending = session[key]
      unless valid_recent_authentication_pending?(pending, scope: scope)
        session[key] = {
          "context" => recent_authentication_context(scope), "issued_at" => Time.current.to_f,
          "return_to" => recent_authentication_return_path(request.get? ? request.fullpath : request.referer)
        }
      end
      redirect_to recent_authentication_confirmation_path(scope: scope)
    end

    def recent_authentication_confirmation_path(scope:)
      mapping = Vouch.mapping_for(scope)
      Vouch.mapping_for(mapping.evidence_scope_name).route_path(:sessions, :confirmation, self, confirmation_scope: scope)
    end

    def recent_authentication_methods
      %w[password oauth two_factor recovery_code]
    end

    def recent_authentication_proof?(proof, within:)
      return false unless proof.is_a?(Hash) && recent_authentication_methods.include?(proof["method"])
      age = Time.current - Time.iso8601(proof.fetch("verified_at"))
      age >= 0 && age < within.to_f
    rescue ArgumentError, KeyError, TypeError
      false
    end

    def recent_authentication_account(scope)
      mapping = Vouch.mapping_for(scope)
      credentials_mapping = Vouch.mapping_for(mapping.evidence_scope_name)
      identity = Vouch.authenticated_identity(request.env.fetch("warden"), credentials_mapping.scope_name, controller: self)
      return unless identity
      if credentials_mapping.split_model? && !credentials_mapping.membership_scope? && Vouch::ImpersonationStack.active?(session)
        Vouch::ImpersonationStack.retained_account(session)
      else
        credentials_mapping.account_for(identity)
      end
    end

    def recent_authentication_actor(scope)
      Vouch::ImpersonationStack.original_account(session) || recent_authentication_account(scope)
    end

    def recent_authentication_context(scope)
      account = recent_authentication_account(scope)
      actor = recent_authentication_actor(scope)
      return unless account && actor
      identity = Vouch.authenticated_identity(request.env.fetch("warden"), scope, controller: self)
      return unless identity

      Digest::SHA256.hexdigest([
        scope.to_s, Vouch::PendingAuthentication.fingerprint(actor),
        Vouch::PendingAuthentication.fingerprint(account), Vouch::RecordKey.serialize(identity),
        Vouch::AuthenticationSession.context_id_for(session)
      ].to_json)
    end

    def record_recent_authentication(scope:, method:, at: Time.current, origin: :confirmation)
      context = recent_authentication_context(scope)
      return unless context
      session[Vouch::Session.key_for(scope, :confirmation)] = {
        "context" => context, "origin" => origin.to_s, "proof" => { "method" => method.to_s, "verified_at" => at.utc.iso8601(6) }
      }
    end

    def recent_sign_in_proof(scope)
      return if Vouch::ImpersonationStack.active?(session)
      confirmation = session[Vouch::Session.key_for(scope, :confirmation)]
      return unless confirmation.is_a?(Hash) && confirmation["origin"] == "sign_in" &&
        confirmation["context"] == recent_authentication_context(scope)
      confirmation["proof"]
    end

    def valid_recent_authentication_pending?(pending, scope:)
      return false unless pending.is_a?(Hash) && pending["issued_at"].is_a?(Numeric)
      age = Time.current.to_f - pending["issued_at"]
      age >= 0 && age < Vouch.configuration.pending_authentication_ttl.to_f &&
        pending["context"] == recent_authentication_context(scope)
    end

    def recent_authentication_return_path(value)
      candidate = url_from(value)
      return "/" unless candidate
      uri = URI.parse(candidate)
      return candidate if uri.relative? && candidate.start_with?("/") && !candidate.start_with?("//")
      return candidate if uri.scheme == request.scheme && uri.host == request.host && uri.port == request.port
      "/"
    rescue URI::InvalidURIError
      "/"
    end
  end
end
