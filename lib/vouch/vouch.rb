# Top-level Vouch module.
#
# Provides the configure block, global configuration access, and the
# mapping registry. Scope mappings are created by the route DSL.
#
#   Vouch.configure do |config|
#     config.lockable.max_failed_attempts = 5
#     config.register_login_resolver MyApp::EmailResolver
#   end
#
#   Vouch.mapping_for(:user)  # => Vouch::Mapping
#
module Vouch
  class ConfigurationError < StandardError; end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    # --- Scope mappings ---

    def mapping_for(scope)
      mappings[scope.to_sym] || raise(ArgumentError, "No Vouch mapping for scope :#{scope}")
    end

    # Iterate over registered mappings. Public-safe alternative to exposing
    # the internal hash directly.
    def each_mapping(&block)
      mappings.each_value(&block)
    end

    # Re-run host reflection checks after boot or during a deployment check.
    # Route registration performs the same validation; this public entry point
    # lets hosts verify loaded models without rebuilding routes.
    def verify!
      Vouch::Verifier.new.verify!
    end

    # True when at least one scope has been registered.
    def mappings?
      mappings.any?
    end

    # True when the given symbol matches a registered scope.
    def registered_scope?(scope)
      mappings.key?(scope.to_sym)
    end

    # Every mapping owns these Warden scopes, including the intermediate
    # account and impersonation sessions.
    def reserved_warden_scopes_for(scope)
      scope = scope.to_sym
      [scope, :"#{scope}_account", :"#{scope}_impersonation"]
    end

    def dependent_mappings(scope)
      each_mapping.select { |mapping| mapping.parent_scope_name == scope.to_sym }
    end

    def authenticated_identity(warden, scope, controller: nil)
      mapping = mapping_for(scope)
      session = warden.raw_session if warden.respond_to?(:raw_session)
      Vouch::ImpersonationStack.discard_invalid!(warden: warden, session: session) if session
      if session && Vouch::ImpersonationStack.active?(session) &&
          (mapping.split_model? || Vouch::ImpersonationStack.target_scope(session) == scope.to_sym)
        target = Vouch::ImpersonationStack.authorized_identity(session, scope: scope)
        identity = warden.user(scope)
        return target if target && identity && identity.class == target.class &&
          Vouch::RecordKey.same?(identity, target, model: target.class)
        return nil
      end
      identity = warden.user(scope)
      return identity unless identity && mapping.membership_scope?

      account = warden.user(mapping.parent_scope_name)
      owner = mapping.account_for(identity)
      return identity if account && owner && account.class == owner.class && account.id == owner.id &&
        membership_authentication_valid?(warden, mapping, identity, controller: controller)

      nil
    end

    def membership_authentication_valid?(warden, mapping, identity, controller: nil)
      policy = configuration.authentication_policy
      policy = policy.constantize if policy.is_a?(String)
      policy = policy.new if policy.is_a?(Class)
      return true unless policy.respond_to?(:membership_mfa_requirements)

      AuthenticationEvidence.membership_valid?(warden.raw_session, mapping, identity,
        policy: policy, controller: controller)
    end

    def logout_scope(warden, session, scope)
      mapping = mapping_for(scope)
      impersonation_scopes = Vouch::ImpersonationStack.logout_scopes(session, scope: scope)
      session.delete(Vouch::ImpersonationStack::SESSION_KEY) if impersonation_scopes.any?
      if mapping.membership_scope? && warden.user(:"#{scope}_impersonation")
        scope = mapping.parent_scope_name
      end
      roots = [scope.to_sym] + impersonation_scopes
      scopes = (roots + roots.flat_map { |name| dependent_mappings(name).map(&:scope_name) }).uniq
      scopes.each do |name|
        mapping = mapping_for(name)
        owned = [name, :"#{name}_impersonation"]
        owned << mapping.account_scope_name unless mapping.membership_scope?
        warden.logout(*owned)
        session.keys.select { |key| Session.state_key?(key, name) }.each { |key| session.delete(key) }
      end
    end

    # Controller namespace inference may fall back only when there is one mapping.
    def single_registered_scope
      return nil unless mappings.size == 1
      mappings.keys.first
    end

    # Internal — RouteBuilder calls this to register a scope mapping.
    def register_mapping(scope, mapping)
      ApplicationHelpers.validate_mapping!(mapping)
      mappings[scope.to_sym] = mapping
      configured_warden_configs.each { |config| configure_warden_scope(config, mapping) }
      ApplicationHelpers.define_scope(scope)
    end

    # Internal — used by tests. Removes a scope mapping.
    def deregister_mapping(scope)
      mappings.delete(scope.to_sym)
      ApplicationHelpers.refresh!
    end

    # The raw mapping registry. Exposed primarily for test setup/teardown.
    # Production code should use mapping_for/each_mapping/register_mapping.
    def mappings
      @mappings ||= {}
    end

    # Configure a Warden manager or Warden::Config supplied by a host that
    # already owns middleware. Existing global defaults are preserved; the
    # Vouch strategy defaults are scoped to registered mappings.
    def configure_warden(manager_or_config)
      warden_config = manager_or_config.respond_to?(:config) ? manager_or_config.config : manager_or_config
      unless warden_config.respond_to?(:scope_defaults) && warden_config.respond_to?(:failure_app=)
        raise ArgumentError, "configure_warden expects a Warden::Manager or Warden::Config"
      end

      failure_app = configuration.warden_failure_app
      failure_app = failure_app.constantize if failure_app.is_a?(String)
      warden_config.failure_app ||= failure_app

      if warden_config.default_strategies.empty? && mappings.empty?
        warden_config.default_strategies(*configuration.warden_default_strategies)
      end

      configured_warden_configs << warden_config unless configured_warden_configs.include?(warden_config)
      each_mapping { |mapping| configure_warden_scope(warden_config, mapping) }
      manager_or_config
    end

    # Route DSL entry point. Called from config/routes.rb:
    #
    #   Vouch.routes(self) do |auth|
    #     auth.scope :user, account: "Account", identity: "User", tenant: "Organisation"
    #   end
    def routes(router, &block)
      builder = RouteBuilder.new(router)
      block.call(builder)
    end

    def configured_warden_configs
      @configured_warden_configs ||= []
    end

    def configure_warden_scope(warden_config, mapping)
      warden_config.scope_defaults(
        mapping.scope_name,
        strategies: mapping.membership_scope? ? [] : configuration.warden_default_strategies
      )
    end

  end

  # Centralized session key generation. Internal — used by strategies and
  # controllers to ensure consistent key naming.
  module Session
    def self.state_key?(key, scope)
      name = key.to_s
      return false if name.match?(/\Awarden\.user\..+\.(?:key|session)\z/)

      name.start_with?("warden.#{scope}.")
    end

    KEY_PURPOSES = {
      two_factor:    "2fa_pending",
      return_to:     "return_to",
      invited_user:  "invited_user_id",
      impersonation: "impersonation_return_to",
      signed_in_via: "signed_in_via",
      selection: "selection",
      oauth_registration: "oauth_registration",
      destination_scope: "destination_scope",
      completion: "completion",
      evidence: "authentication_evidence"
    }.freeze

    def self.key_for(scope, purpose)
      suffix = KEY_PURPOSES[purpose] || raise(ArgumentError, "Unknown session key purpose: #{purpose}")
      "warden.#{scope}.#{suffix}"
    end

    # Per-record dynamic purposes (e.g., "verify_email_42") don't fit the
    # KEY_PURPOSES registry — there are arbitrarily many of them. This
    # bypasses the registry's enum validation. The "warden." prefix matches
    # the warden-managed key namespace so session-clearing helpers that wipe
    # "warden.*" keys also wipe these.
    def self.dynamic_key_for(scope, purpose_string)
      "warden.#{scope}.#{purpose_string}"
    end
  end
end
