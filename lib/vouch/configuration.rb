# frozen_string_literal: true

# Global configuration for Vouch.
#
# Feature settings are namespaced under sub-config objects. Models can override
# individual values via `authenticates_with` options.
#
#   Vouch.configure do |config|
#     config.lockable.max_failed_attempts = 10
    #     config.lockable.lockout_duration    = 30.minutes
#
#     config.register_login_resolver Vouch::LoginResolver::EmailResolver
#   end
#
module Vouch
  class Configuration
    # --- Feature config namespaces ---
    attr_reader :lockable, :password_trackable, :password_resetable, :invitations

    # --- Top-level settings (not feature-specific) ---

    # Optional application display name for host integrations. Vouch
    # does not consume this setting directly.
    attr_accessor :app_name

    # Session-key suffix for credential drafts (Email/Phone/Totp records
    # stashed unpersisted while a user registers or adds a credential).
    # Final key is `"warden.#{auth_scope_name}.#{suffix}"` — per-scope
    # isolation falls out of the interpolation.
    attr_accessor :credential_drafts_session_suffix

    # Root lockout duration; sub-configs inherit when not overridden.
    attr_accessor :lockout_duration

    # Warden middleware knobs — read by the engine when registering the manager.
    attr_accessor :warden_default_strategies, :warden_failure_app,
                  :parent_controller, :authentication_callbacks,
                  :pending_authentication_ttl, :preserved_session_keys,
                  :preserved_auth_scopes, :oauth_mfa_providers,
                  :authentication_policy, :install_middleware

    def initialize
      @lockable           = LockableConfig.new(self)
      @password_trackable = PasswordTrackableConfig.new
      @password_resetable = PasswordResetableConfig.new
      @invitations        = InvitationsConfig.new

      @app_name                         = nil
      @credential_drafts_session_suffix = "credential_drafts"

      @lockout_duration = 30.minutes

      @warden_default_strategies = [:password]
      @warden_failure_app        = "Vouch::FailureApp"

      @parent_controller          = "ApplicationController"
      @authentication_callbacks    = []
      @pending_authentication_ttl  = 10.minutes
      @preserved_session_keys      = []
      @preserved_auth_scopes       = []
      @oauth_mfa_providers         = []
      @authentication_policy       = "Vouch::AuthenticationPolicy"
      @install_middleware          = true

      @login_resolver_names = []
    end

    # New-style memoized accessors for the concerns that replaced the
    # ad-hoc OTP/2FA path. Lazy so host apps that don't use the feature
    # never instantiate the config.
    def verifiable
      @verifiable ||= VerifiableConfig.new(self)
    end

    def two_factorable
      @two_factorable ||= TwoFactorableConfig.new(self)
    end

    def magic_linkable
      @magic_linkable ||= MagicLinkableConfig.new(self)
    end

    def backup_codable
      @backup_codable ||= BackupCodableConfig.new(self)
    end

    def recoverable
      @recoverable ||= RecoverableConfig.new(self)
    end

    # Register a login resolver class. Resolvers are tried in order; first
    # match wins. Named classes are stored by constant name so Rails reloads
    # resolve the current class instead of retaining stale class objects.
    #
    #   config.register_login_resolver Vouch::LoginResolver::EmailResolver
    #   config.register_login_resolver MyApp::PhoneResolver
    #
    def register_login_resolver(resolver_class)
      name = resolver_class.respond_to?(:name) ? resolver_class.name : nil
      @login_resolver_names << (name.presence || resolver_class)
    end

    # Lazy login resolver instantiation. Each call returns fresh instances so
    # resolvers can hold per-request state safely.
    def login_resolvers
      @login_resolver_names.filter_map do |name|
        resolver_class = name.is_a?(String) ? name.constantize : name
        resolver_class.new
      rescue NameError => e
        raise ConfigurationError, "Configured login resolver #{name.inspect} could not be loaded: #{e.message}"
      end
    end

    # Resolve the currently loaded resolver classes. This is useful to hosts
    # that inspect the registry while keeping the registry itself reload-safe.
    def login_resolver_classes
      @login_resolver_names.filter_map do |name|
        name.is_a?(String) ? name.constantize : name
      rescue NameError => e
        raise ConfigurationError, "Configured login resolver #{name.inspect} could not be loaded: #{e.message}"
      end
    end
  end
end
