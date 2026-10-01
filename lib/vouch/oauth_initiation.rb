# frozen_string_literal: true

require "uri"

module Vouch
  class OAuthInitiation
    RETURN_TO_SUFFIX = "oauth_initiation_return_to"
    REQUEST_PARAM = "vouch_request_id"
    PURPOSES = %w[sign_in register link].freeze

    def self.install(stack)
      return unless defined?(OmniAuth::Builder) && stack.any? { |middleware| middleware.klass == OmniAuth::Builder }

      if stack.any? { |middleware| middleware.klass == Warden::Manager }
        stack.move_before OmniAuth::Builder, Warden::Manager
      end
      stack.delete(self)
      stack.insert_before OmniAuth::Builder, self
    end

    def self.contexts_key(scope)
      Vouch::Session.dynamic_key_for(scope, "oauth_requests")
    end

    def self.prune_contexts!(session, scope)
      key = contexts_key(scope)
      contexts = session[key]
      return session.delete(key) unless contexts.is_a?(Hash)

      cutoff = Time.current.to_f - Vouch.configuration.pending_authentication_ttl.to_f
      contexts.delete_if { |_, context| !context.is_a?(Hash) || context["issued_at"].to_f < cutoff }
      contexts.shift while contexts.size > 5
    end

    def self.return_to_key(scope)
      Vouch::Session.dynamic_key_for(scope, RETURN_TO_SUFFIX)
    end

    def initialize(app)
      @app = app
    end

    def call(env)
      request = ActionDispatch::Request.new(env)
      mapping = mapping_for(request) if request.post?
      if mapping
        key = self.class.return_to_key(mapping.scope_name)
        request.session.delete(key)
        if (return_to = local_referer_path(request))
          request.session[key] = return_to
        end
        capture_context(request, mapping)
      end

      @app.call(env)
    end

    private

    def capture_context(request, mapping)
      purpose = request.params.fetch("purpose", "sign_in").to_s
      purpose = "invalid" unless PURPOSES.include?(purpose)
      identity = request.env["warden"]&.user(mapping.membership_scope? ? mapping.parent_scope_name : mapping.scope_name)
      account = mapping.membership_scope? ? identity : (mapping.account_for(identity) if identity)
      self.class.prune_contexts!(request.session, mapping.scope_name)
      contexts = request.session[self.class.contexts_key(mapping.scope_name)] ||= {}
      contexts.shift while contexts.size >= 5
      nonce = SecureRandom.hex(24)
      contexts[nonce] = {
        "purpose" => purpose,
        "reconnect_uid" => request.params["reconnect_uid"].presence&.to_s,
        "invitation" => request.session[Vouch::Session.key_for(mapping.scope_name, :invited_user)]&.deep_dup,
        "provider" => request.path.split("/").last,
        "scope" => mapping.scope_name.to_s,
        "account_scope" => mapping.evidence_scope_name.to_s,
        "account_id" => account && Vouch::RecordKey.serialize(account),
        "fingerprint" => account && Vouch::PendingAuthentication.fingerprint(account),
        "context_id" => Vouch::AuthenticationSession.context_id_for(request.session),
        "issued_at" => Time.current.to_f
      }

      # OmniAuth preserves request GET parameters in its validated callback environment.
      query = request.query_parameters.merge(REQUEST_PARAM => nonce)
      request.env["QUERY_STRING"] = Rack::Utils.build_nested_query(query)
      request.env.delete("action_dispatch.request.query_parameters")
      request.env.delete("rack.request.query_hash")
      request.env.delete("rack.request.query_string")
    end

    def mapping_for(request)
      Vouch.each_mapping.find do |mapping|
        prefix = callback_prefix(mapping)
        match = prefix && request.path.match(%r{\A#{Regexp.escape(prefix)}/([^/]+)\z})
        mapping.oauth_callbacks_enabled && match && match[1] != "failure"
      end
    end

    def callback_prefix(mapping)
      callback_path = mapping.oauth_callback_path
      return unless callback_path&.end_with?("/:provider/callback")

      callback_path.delete_suffix("/:provider/callback")
    end

    def local_referer_path(request)
      return if request.referer.blank?

      uri = URI.parse(request.referer)
      if uri.host
        return unless uri.scheme == request.protocol.delete_suffix("://") &&
          uri.host == request.host && uri.port == request.port
      end

      path = uri.host ? uri.request_uri : uri.to_s
      path if path.start_with?("/") && !path.start_with?("//", "/\\")
    rescue URI::InvalidURIError
      nil
    end
  end
end
