# frozen_string_literal: true

require "uri"

module Vouch
  class OAuthInitiation
    RETURN_TO_SUFFIX = "oauth_initiation_return_to"

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
      end

      @app.call(env)
    end

    private

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
