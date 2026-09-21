# frozen_string_literal: true

# Scope mapping that ties an authentication scope to its models, paths, and helpers.
#
# Created by the route DSL (`auth.scope`). Each mapping connects:
#   - A Warden scope name (:user, :admin, :member)
#   - An account class (holds credentials)
#   - An identity class (the object Warden serializes into session)
#   - An optional tenant class (organisation/workspace that owns identities)
#   - Route paths and helper prefixes
#
# Feature associations (OAuth, 2FA, password archives) are discovered
# automatically by scanning Account's has_many targets for concern inclusion.
#
# Split-model (Account + User):
#   Vouch::Mapping.new(:user, account: "Account", identity: "User")
#
# Split-model with tenant:
#   Vouch::Mapping.new(:user, account: "Account", identity: "User", tenant: "Organisation")
#
# Single-model (same class for both):
#   Vouch::Mapping.new(:member, model: "Member")
#
module Vouch
  class Mapping
    ASSOCIATION_KEYS = %i[
      account_identities identity_account identity_tenant tenant_identities
      omniauthable oauth_account two_factorable password_trackable
      verifiable magic_linkable
    ].freeze

    attr_reader :scope_name, :account_class_name, :identity_class_name,
                :tenant_class_name, :path, :helper_prefix,
                :identity_association, :account_association,
                :oauth_callback_path, :oauth_failure_path,
                :oauth_callback_methods, :oauth_failure_methods

    # Resolved eagerly by resolve_reflections!. Internal — controllers and
    # strategies reach for associations through helper methods on Mapping
    # rather than touching these readers directly.
    attr_reader :tenant_identity_association, :identity_tenant_association,
                :oauth_identity_association, :oauth_account_association,
                :two_factor_credential_associations,
                :password_archive_association,
                :credential_associations

    def initialize(scope_name, account: nil, identity: nil, model: nil,
                   tenant: nil, path: nil, as: nil,
                   associations: {}, oauth_callback_path: nil,
                   oauth_failure_path: nil, oauth_callback_methods: nil,
                   oauth_failure_methods: nil)
      if model && (account || identity || tenant)
        conflicting = []
        conflicting << "account:" if account
        conflicting << "identity:" if identity
        conflicting << "tenant:" if tenant

        raise Vouch::ConfigurationError, <<~MSG.squish
          A single-model mapping using model: cannot also specify
          #{conflicting.join(', ')}. Use account: and identity: for a split-model
          mapping; tenant: is supported only with split-model mappings.
        MSG
      end

      @scope_name = scope_name

      if model
        @account_class_name  = model.to_s
        @identity_class_name = model.to_s
        @split_model = false
      else
        raise ArgumentError, "Provide either model: or both account: and identity:" unless account && identity
        @account_class_name  = account.to_s
        @identity_class_name = identity.to_s
        @split_model = true
      end

      @tenant_class_name    = tenant&.to_s
      @path                 = path || scope_name.to_s.pluralize
      @helper_prefix        = (as || scope_name).to_sym
      @associations         = (associations || {}).deep_symbolize_keys
      unknown_association_keys = @associations.keys - ASSOCIATION_KEYS
      if unknown_association_keys.any?
        raise ConfigurationError, "Unsupported associations: #{unknown_association_keys.map(&:inspect).join(', ')}"
      end
      @relationship_overrides = @associations.slice(
        :account_identities, :identity_account, :identity_tenant,
        :tenant_identities, :oauth_account
      )
      @identity_association = @relationship_overrides[:account_identities] ||
        identity_class_name.demodulize.underscore.pluralize.to_sym
      @account_association = @relationship_overrides[:identity_account] || :account
      @oauth_callback_path  = oauth_callback_path
      @oauth_failure_path   = oauth_failure_path
      @oauth_callback_methods = Array(oauth_callback_methods || :get).map { |method| method.to_s.upcase }.freeze
      @oauth_failure_methods  = Array(oauth_failure_methods || :get).map { |method| method.to_s.upcase }.freeze
    end

    def account_class
      account_class_name.constantize
    end

    def identity_class
      identity_class_name.constantize
    end

    def tenant_class
      return nil unless tenant_class_name

      tenant_class_name.constantize
    end

    # Retained for the engine's reload hook. Model classes resolve from their
    # names on each access, so there is no class cache to clear.
    def reset_class_cache!
    end

    def association_name(feature)
      value = @associations[feature.to_sym]
      value.is_a?(Array) ? value.map(&:to_sym) : value&.to_sym
    end

    # Internal seam for ReflectionResolver; feature discovery remains owned by
    # this mapping so route configuration keeps its existing contract.
    def auth_feature_enabled_for_resolution?(feature)
      auth_feature_enabled?(feature)
    end

    def split_model?
      @split_model
    end

    # Warden scope name for the mid-flow account tier. Set after password
    # verification (and 2FA, if enabled), cleared once an identity is bound
    # to the primary scope. Mirrors the impersonation scope pattern.
    def account_scope_name
      :"#{scope_name}_account"
    end

    def tenant?
      tenant_class_name.present?
    end

    # Resolve identity/identities from an account.
    # Single-model: returns [account] (account IS the identity).
    # Split-model: returns the association collection.
    def identities_for(account)
      if split_model?
        account.send(identity_association)
      else
        [account]
      end
    end

    # Walk back from an identity to its owning account.
    # Single-model: identity IS the account.
    def account_for(identity)
      split_model? ? identity.send(account_association) : identity
    end

    # Resolve the account behind an OAuth identity using the same configured
    # owner association as ordinary identities. This keeps OAuth linking and
    # sign-in compatible with mappings such as `belongs_to :owner`.
    def account_for_oauth_identity(oauth_identity)
      return oauth_identity if oauth_identity.is_a?(account_class)

      association = oauth_account_association || infer_oauth_account_association(oauth_identity.class)
      oauth_identity.public_send(association.name)
    end

    # Strong-params key for the account (e.g. :account, :member, :admin_user).
    def account_param_key
      @account_param_key ||= account_class.model_name.param_key.to_sym
    end

    # True when the account maps to exactly one identity and no user selection
    # screen is needed. Single-model is always single-identity.
    def single_identity_login?(identities)
      return true unless split_model?

      count = identities.respond_to?(:count) ? identities.count : identities.size
      count == 1
    end

    # Safely extract the first identity from a collection or array.
    def first_identity(identities)
      return identities if identities.is_a?(ActiveRecord::Base)

      identities.respond_to?(:first) ? identities.first : Array(identities).first
    end

    # Resolve the URL path for a Warden failure action. `helper_context`
    # must respond to the scope-prefixed Rails route helpers.
    def failure_path_for(action, helper_context)
      case action.to_s
      when "two_factor_challenges"
        helper_context.send(:"#{helper_prefix}_two_factor_challenges_path")
      else
        helper_context.send(:"new_#{helper_prefix}_session_path")
      end
    end

    def oauth_identity_class
      oauth_identity_association&.klass
    end

    # Back-compat accessor: returns the first TwoFactorable association.
    # Prefer `two_factor_credential_associations` (plural) when the host
    # has more than one 2FA-bearing model (e.g. Email + Phone + Totp).
    def two_factor_credential_association
      Array(two_factor_credential_associations).first
    end

    def two_factor_association_configured?
      association_name(:two_factorable).present?
    end


    # Eagerly resolve all associations at boot. Called by RouteBuilder after
    # Warden scope registration. Raises ConfigurationError if a required
    # association is missing or an enabled feature's optional gem is unavailable.
    def resolve_reflections!
      validate_invitable_placement!
      validate_identity_association! if split_model?
      resolve_tenant_associations! if tenant?
      validate_optional_dependencies!

      @oauth_identity_association = nil
      @oauth_identity_association = resolve_association_by_concern(
        Vouch::OAuthIdentity::Concern, :omniauthable, "OAuth identity",
        association_name(:omniauthable)
      ) if oauth_feature_configured? && defined?(Vouch::OAuthIdentity::Concern)
      @oauth_account_association = resolve_oauth_account_association! if @oauth_identity_association

      @two_factor_credential_associations =
        if two_factor_feature_configured? && defined?(Vouch::TwoFactorable)
          resolve_associations_by_concern(
            Vouch::TwoFactorable, :two_factorable, "2FA credential",
            association_name(:two_factorable)
          )
        else
          [].freeze
        end

      @credential_associations = {}
      %i[verifiable magic_linkable].each do |feature|
        concern = Vouch.const_get(feature.to_s.camelize)
        @credential_associations[feature] = resolve_associations_by_concern(
          concern, nil, "#{feature} credential", association_name(feature)
        )
      end

      @password_archive_association = nil
      if password_archive_feature_configured?
        @password_archive_association = account_class.password_archive_reflection
        configured = association_name(:password_trackable)
        if configured && configured != @password_archive_association.name
          raise ConfigurationError, "Configure the password history association on #{account_class_name}, not on individual route scopes."
        end
      end
    end

    private

    # Feature → required gem mapping. When a feature is enabled but its gem
    # isn't loadable, raise with actionable install instructions.
    OPTIONAL_FEATURE_DEPS = {
      omniauthable:   { gem: "omniauth", require: "omniauth" }
    }.freeze

    def validate_optional_dependencies!
      OPTIONAL_FEATURE_DEPS.each do |feature, dep|
        next unless account_class.respond_to?(:auth_feature_enabled?)
        configured = feature == :omniauthable ? oauth_feature_configured? : auth_feature_enabled?(feature)
        next unless configured

        begin
          require dep[:require]
        rescue LoadError
          raise ConfigurationError, <<~MSG.squish
            #{account_class_name} has :#{feature} enabled but the '#{dep[:gem]}' gem
            is not available. Add `gem "#{dep[:gem]}"` to your Gemfile and run
            `bundle install`.
          MSG
        end
      end
    end

    def validate_invitable_placement!
      return unless split_model? && auth_feature_enabled?(:invitable)

      raise ConfigurationError, <<~MSG.squish
        #{account_class_name} enables :invitable for a split-model mapping, but
        invitations belong on #{identity_class_name}. Include
        Vouch::Invitable::Concern on #{identity_class_name} instead.
      MSG
    end

    def validate_identity_association!
      @identity_association = relationship(account_class, :has_many, identity_class,
        :account_identities).name
      @account_association = relationship(identity_class, :belongs_to, account_class,
        :identity_account).name
    end

    def resolve_tenant_associations!
      @tenant_identity_association = relationship(tenant_class, :has_many, identity_class, :tenant_identities)
      @identity_tenant_association = relationship(identity_class, :belongs_to, tenant_class, :identity_tenant)
    end

    def resolve_oauth_account_association!
      reflection_resolver.oauth_account_association(
        oauth_identity_association, account_class, account_class_name,
        explicit: @relationship_overrides[:oauth_account]
      )
    end

    def infer_oauth_account_association(oauth_class)
      reflection_resolver.infer_oauth_account_association(oauth_class, account_class, account_class_name)
    end

    def relationship(owner, macro, target, key)
      reflection_resolver.relationship(owner, macro, target, key, @relationship_overrides)
    end

    # Scan Account's has_many associations for a target that includes the given
    # concern module. Raises if the feature is enabled but no association is found.
    def resolve_association_by_concern(concern_module, feature_flag, label, explicit_name = nil)
      assocs = reflection_resolver.by_concern(account_class, :has_many, concern_module,
        explicit_names: explicit_name, feature_flag: feature_flag, label: label)
      return assocs unless assocs.is_a?(Array)

      if assocs.length > 1
        raise ConfigurationError, <<~MSG.squish
          #{account_class_name} has multiple has_many targets including #{concern_module}
          for :#{feature_flag}: #{assocs.map(&:name).join(', ')}. Configure the association
          explicitly with associations: { #{feature_flag}: :name }.
        MSG
      end

      assoc = assocs.first
      if assoc.nil?
        raise ConfigurationError, <<~MSG.squish
          #{account_class_name} has :#{feature_flag} enabled but no has_many target
          includes #{concern_module}. Add `include #{concern_module}` to your
          #{label} model and declare `has_many :your_#{label.tr(' ', '_').pluralize}`
          on #{account_class_name}.
        MSG
      end

      assoc
    end

    # Plural form of resolve_association_by_concern. Returns every has_many
    # association whose target class includes the given concern module.
    # Used for 2FA where a host can attach the concern to multiple credential
    # types (Email + Phone + Totp).
    def resolve_associations_by_concern(concern_module, feature_flag, label, explicit_names = nil)
      assocs = reflection_resolver.by_concern(account_class, :has_many, concern_module,
        explicit_names: explicit_names, feature_flag: feature_flag, label: label)
      assocs = [assocs] unless assocs.is_a?(Array)
      if assocs.empty?
        if feature_flag && account_class.respond_to?(:auth_feature_enabled?) && account_class.auth_feature_enabled?(feature_flag)
          raise ConfigurationError, <<~MSG.squish
            #{account_class_name} has :#{feature_flag} enabled but no has_many target
            includes #{concern_module}. Add `include #{concern_module}` to your
            #{label} model and declare `has_many :your_#{label.tr(' ', '_').pluralize}`
            on #{account_class_name}.
          MSG
        end
        return assocs
      end

      assocs.freeze
    end

    def auth_feature_enabled?(feature)
      account_class.respond_to?(:auth_feature_enabled?) && account_class.auth_feature_enabled?(feature)
    end

    def oauth_feature_configured?
      auth_feature_enabled?(:omniauthable) || association_name(:omniauthable).present?
    end

    def two_factor_feature_configured?
      auth_feature_enabled?(:two_factorable) || association_name(:two_factorable).present?
    end

    def password_archive_feature_configured?
      auth_feature_enabled?(:password_trackable) || association_name(:password_trackable).present?
    end

    def reflection_resolver
      @reflection_resolver ||= Vouch::Mapping::ReflectionResolver.new(self)
    end
  end
end
