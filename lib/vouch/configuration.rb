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
#     config.login_resolvers = [Vouch::LoginResolver::EmailResolver]
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
                  :pending_authentication_ttl,
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

      @pending_authentication_ttl  = 10.minutes
      @authentication_policy       = "Vouch::AuthenticationPolicy"
      @install_middleware          = true

      @login_resolver_names = []
      @model_login_resolvers = {}
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

    def recovery_codes
      @recovery_codes ||= RecoveryCodesConfig.new
    end

    def recoverable
      @recoverable ||= RecoverableConfig.new(self)
    end

    def login_resolvers=(resolvers)
      @login_resolver_names = resolver_names(resolvers)
    end

    def login_resolvers_for(model, with:)
      @model_login_resolvers[model_name(model)] = resolver_names(with)
    end

    def reset_login_resolvers_for(model)
      @model_login_resolvers.delete(model_name(model))
    end

    def login_resolvers(model: nil)
      login_resolver_classes(model: model).map(&:new)
    end

    def login_resolver_classes(model: nil)
      names = model ? @model_login_resolvers.fetch(model_name(model), @login_resolver_names) : @login_resolver_names
      names.map do |name|
        name.is_a?(String) ? name.constantize : name
      rescue NameError => error
        raise ConfigurationError, "Configured login resolver #{name.inspect} could not be loaded: #{error.message}"
      end
    end

    private

    def resolver_names(resolvers)
      unless resolvers.is_a?(Array)
        raise ConfigurationError, "Login resolvers must be an ordered Array of classes or class names"
      end
      resolvers.map do |resolver|
        resolver.respond_to?(:name) ? (resolver.name.presence || resolver) : resolver
      end
    end

    def model_name(model)
      name = model.respond_to?(:name) ? model.name : model.to_s
      raise ConfigurationError, "A named credentials model is required" if name.blank?
      name
    end
  end
end
