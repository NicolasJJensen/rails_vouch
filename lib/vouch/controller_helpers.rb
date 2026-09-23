require "set"

module Vouch
  module ControllerHelpers
    extend ActiveSupport::Concern
    include Vouch::RegistrationHelpers
    include Vouch::InvitationHelpers
    include Vouch::LifecycleHooks
    include Vouch::AuthenticationCompletion

    AUTH_LIFECYCLE_HOOKS = %i[
      sign_in
      sign_out
      sign_up
      oauth_sign_in
      oauth_link
      oauth_account_creation
      invitation_revocation
      impersonation_start
      impersonation_end
    ].freeze

    AUTH_EVENT_HOOKS = %i[
      password_reset_token_generation
      password_change
      invitation_token_generation
      invitation_acceptance
      two_factor_verification
    ].freeze

    ALL_AUTH_HOOKS = (AUTH_LIFECYCLE_HOOKS + AUTH_EVENT_HOOKS).freeze

    private_constant :AUTH_LIFECYCLE_HOOKS, :AUTH_EVENT_HOOKS, :ALL_AUTH_HOOKS

    UNSAFE_REDIRECT_PATTERN = /\A(?!\/)|\A(?:\/\/|\\|\/\\)|%2f|%2e|[\u{202a}-\u{202e}\u{2066}-\u{2069}]/i
    private_constant :UNSAFE_REDIRECT_PATTERN

    included do
      include ActiveHooks::Callbacks

      class_attribute :_auth_scope_name, instance_writer: false

      define_hooks(*ALL_AUTH_HOOKS)
    end

    class_methods do
      def auth_scope(scope_name)
        self._auth_scope_name = scope_name.to_sym
      end

      AUTH_LIFECYCLE_HOOKS.each do |hook_name|
        %i[before after around].each do |kind|
          define_method(:"#{kind}_#{hook_name}") do |*args, **opts, &block|
            set_hook(hook_name, kind, *args, **opts, &block)
          end
        end
      end

      AUTH_EVENT_HOOKS.each do |hook_name|
        define_method(:"on_#{hook_name}") do |*args, **opts, &block|
          set_hook(hook_name, :on, *args, **opts, &block)
        end
      end
    end

    private

    def auth_mapping
      Vouch.mapping_for(auth_scope_name)
    end

    def auth_scope_name
      _auth_scope_name || inferred_auth_scope_name
    end

    def inferred_auth_scope_name
      segments = controller_path.split("/").reject { |s| s == "vouch" }

      segments.reverse.each do |segment|
        candidate = segment.singularize.to_sym
        return candidate if Vouch.registered_scope?(candidate)
      end

      single = Vouch.single_registered_scope
      return single if single

      raise Vouch::ConfigurationError, <<~MSG.squish
        Could not infer auth scope from controller_path "#{controller_path}".
        Declare it explicitly with `auth_scope :scope_name` in the controller,
        or register a scope in config/routes.rb.
      MSG
    end

    def two_factor_session_key
      Vouch::Session.key_for(auth_scope_name, :two_factor)
    end

    def account_scope_name
      auth_mapping.account_scope_name
    end

    def impersonation_scope
      :"#{auth_scope_name}_impersonation"
    end

    def return_to_session_key
      Vouch::Session.key_for(auth_scope_name, :return_to)
    end

    def invited_user_session_key
      Vouch::Session.key_for(auth_scope_name, :invited_user)
    end

    def oauth_registration_session_key
      Vouch::Session.key_for(auth_scope_name, :oauth_registration)
    end

    def impersonation_return_to_session_key
      Vouch::Session.key_for(auth_scope_name, :impersonation)
    end

    def signed_in_via_session_key
      Vouch::Session.key_for(auth_scope_name, :signed_in_via)
    end

    def signed_in_via
      session[signed_in_via_session_key]
    end

    def credential_drafts_session_key
      Vouch::Session.dynamic_key_for(
        auth_scope_name,
        Vouch.configuration.credential_drafts_session_suffix
      )
    end

    def credential_drafts
      session[credential_drafts_session_key] ||=
        {}
    end

    def credential_drafts=(value)
      session[credential_drafts_session_key] = value
    end

    def clear_credential_drafts
      session.delete(credential_drafts_session_key)
    end

    def reset_session_with_preserved_keys
      authentication_session.reset_with_preserved_keys
    end

    def safe_local_path(value)
      return nil if value.blank?
      return nil unless value.is_a?(String)
      return nil if value.match?(UNSAFE_REDIRECT_PATTERN)

      value
    end

    def redirect_back_or_default(default, **options)
      raw = session.delete(return_to_session_key) || session.delete(:return_to)
      redirect_to(safe_local_path(raw) || default, **options)
    end

    def authentication_policy
      return @authentication_policy if defined?(@authentication_policy)

      policy = Vouch.configuration.authentication_policy
      policy = policy.constantize if policy.is_a?(String)
      @authentication_policy = policy.is_a?(Class) ? policy.new : policy
    end

    def authentication_allowed?(account, context)
      authentication_policy.allowed?(account, method: context['method'], provider: context['provider'], controller: self)
    end

    def needs_second_factor?(account, context)
      authentication_policy.two_factor_required?(account, method: context['method'], provider: context['provider'], controller: self)
    end

    def selection_session_key
      Vouch::Session.key_for(auth_scope_name, :selection)
    end

    def context_credential(account, context)
      reference = context['factor']
      return nil unless reference
      two_factor_credentials_for(account).enabled.detect do |candidate|
        candidate.class.name == reference['type'] && candidate.id.to_s == reference['id']
      end
    end

    def credential_reference(credential)
      {'type' => credential.class.name, 'id' => credential.id.to_s,
        'version' => credential.try(:verification_version),
        'verified_at' => credential.verified_at&.utc&.iso8601(6),
        'used_at' => credential.two_factor_last_used_at&.utc&.iso8601(6)}
    end

    def signed_in_via_reference(credential)
      { 'type' => credential.class.name, 'id' => credential.id.to_s }
    end

    def valid_context_factor?(account, context)
      return true unless context['factor_required'] || needs_second_factor?(account, context)
      factor = context_credential(account, context)
      factor && factor.two_factor_enabled? && factor.verified? && !factor.two_factor_locked? &&
        credential_reference(factor) == context['factor']
    end

    def candidate_identities_for(account)
      auth_mapping.identities_for(account)
    end

    def after_sign_in_path
      after_sign_in_path_for(current_identity, scope: auth_scope_name)
    end

    def after_sign_out_path
      after_sign_out_path_for(scope: auth_scope_name)
    end

    def after_sign_up_path
      after_sign_up_path_for(current_identity, scope: auth_scope_name)
    end

    def redirect_after_authentication(**options)
      target = session.delete(Vouch::Session.key_for(auth_scope_name, :destination_scope))
      if target && Vouch.registered_scope?(target)
        mapping = Vouch.mapping_for(target)
        if mapping.parent_scope_name == auth_scope_name
          completion = session.delete(Vouch::Session.key_for(auth_scope_name, :completion))
          session[Vouch::Session.key_for(mapping.scope_name, :completion)] = completion if completion
          destination = session.delete(return_to_session_key)
          session[Vouch::Session.key_for(mapping.scope_name, :return_to)] ||= destination if destination
          return redirect_to public_send(:"new_#{mapping.helper_prefix}_session_path"), **options
        end
      end
      completion = session.delete(Vouch::Session.key_for(auth_scope_name, :completion))
      if completion == "sign_up"
        session.delete(return_to_session_key)
        redirect_to after_sign_up_path, **options
      else
        redirect_back_or_default after_sign_in_path, **options
      end
    end

    def failed_login_message
      I18n.t("vouch.sessions.invalid_credentials")
    end

    def new_session_path
      send(:"new_#{auth_mapping.helper_prefix}_session_path")
    end

    def session_path
      send(:"#{auth_mapping.helper_prefix}_session_path")
    end

    def sign_out_path
      send(:"#{auth_mapping.helper_prefix}_sign_out_path")
    end

    def new_registration_path
      send(:"new_#{auth_mapping.helper_prefix}_registration_path")
    end

    def select_path
      send(:"#{auth_mapping.helper_prefix}_select_path")
    end

    def two_factor_challenges_path
      send(:"#{auth_mapping.helper_prefix}_two_factor_challenges_path")
    end

    def two_factor_credentials_path
      send(:"#{auth_mapping.helper_prefix}_two_factor_credentials_path")
    end

    def warden
      request.env.fetch('warden')
    end

    def serialize_oauth(auth_hash)
      hash = auth_hash.to_h.stringify_keys
      info = hash.fetch('info', {}).to_h.stringify_keys.slice('email', 'name', 'image')
      {'provider' => hash['provider'], 'uid' => hash['uid'], 'info' => info}
    end

    def parse_oauth(payload)
      OmniAuth::AuthHash.new(payload)
    end

    def oauth_registration_required?
      false
    end

    def begin_oauth_registration(auth_hash)
      authentication_session.begin_oauth_registration!(auth_hash)
    end

    def pending_oauth_registration
      authentication_session.load_oauth_registration
    end

    def oauth_registration_context?
      authentication_session.oauth_registration_present?
    end

    def clear_oauth_registration
      authentication_session.clear_oauth_registration
    end

    def authentication_session
      @authentication_session ||= Vouch::AuthenticationSession.new(self)
    end

    def current_identity
      Vouch.authenticated_identity(warden, auth_scope_name)
    end

    def current_account
      if auth_mapping.membership_scope?
        warden.user(auth_mapping.parent_scope_name)
      else
        pending_select_account || (current_identity && auth_mapping.account_for(current_identity))
      end
    end

    def pending_select_account
      authentication_session.load_selection&.account
    end

    def require_pending_select!
      redirect_to(new_session_path) unless pending_select_account
    end

    def single_identity_login?(identities)
      auth_mapping.single_identity_login?(identities)
    end

    def first_identity(identities)
      auth_mapping.first_identity(identities)
    end

    def two_factor_credentials_for(account)
      assocs = auth_mapping.two_factor_credential_associations

      if assocs.nil? || assocs.empty?
        raise Vouch::ConfigurationError, <<~MSG.squish
          No 2FA credential association found for #{auth_mapping.account_class_name}.
          Enable :two_factorable via authenticates_with and add a has_many
          association to a model that includes Vouch::TwoFactorable.
        MSG
      end

      set = Vouch::CredentialSet.new(account, assocs)
      return set unless signed_in_via

      type = signed_in_via["type"] || signed_in_via[:type]
      id   = (signed_in_via["id"] || signed_in_via[:id]).to_s
      set.reject { |cred| cred.class.name == type && cred.id.to_s == id }
    end

    def two_factor_token_session_key(credential)
      Vouch::Session.dynamic_key_for(
        auth_scope_name,
        "two_factor_token.#{credential.class.name}.#{credential.id}"
      )
    end

    def password_archives_for(account)
      assoc = auth_mapping.password_archive_association

      unless assoc
        raise Vouch::ConfigurationError, <<~MSG.squish
          No password archive association found for #{auth_mapping.account_class_name}.
          Enable :password_trackable via authenticates_with and add a has_many
          association to a model that includes Vouch::PasswordArchive::Concern.
        MSG
      end

      account.send(assoc.name)
    end

  end
end
