# Core authentication concern.
#
# Provides login hooks and the `authenticates_with` DSL for declaring
# features and per-model overrides. Field validations (email, password)
# are the host app's responsibility.
#
#   class Account < ApplicationRecord
#     include Vouch::Authenticatable
#
#     authenticates_with :lockable, :password_resetable, :password_trackable,
#                        :two_factorable, :omniauthable,
#                        lockable: { max_failed_attempts: 10, lockout_duration: 30.minutes }
#
#     has_secure_password
#   end
#
# `:two_factorable` is a marker — the actual TwoFactorable concern lives
# on credential models (Email, Phone, AuthenticatorCode) that the Account
# has_many of. The marker tells strategies and route builders that this
# scope participates in the 2FA challenge flow.
#
module Vouch
  module Authenticatable
    extend ActiveSupport::Concern

    included do
      include Vouch::LoginResolution

      class_attribute :auth_features, instance_writer: false, default: []
      class_attribute :auth_options, instance_writer: false, default: {}
    end

    # Called after successful password verification.
    # Auth concerns chain onto this via super.
    def successful_login!
    end

    # Called after failed password verification.
    # Auth concerns chain onto this via super.
    def failed_login!
    end

    # Default lockable predicate. Overridden by Lockable::Concern when included.
    def locked?
      false
    end

    def invalidate_authentication_sessions!
      unless has_attribute?(:auth_session_version)
        raise Vouch::ConfigurationError, "Add an auth_session_version integer column with default: 0, null: false to #{self.class.table_name}"
      end

      with_lock do
        Vouch::Persistence.update!(self, auth_session_version: auth_session_version.to_i + 1)
      end
    end

    class_methods do
      # Declare which auth features this model uses, with optional per-model overrides.
      #
      #   authenticates_with :lockable, :two_factorable,
      #     lockable: { max_failed_attempts: 10, lockout_duration: 30.minutes },
      #     two_factorable: { max_attempts: 3 }
      #
      # Features are mapped to concerns under Vouch::.
      # Options use nested hash syntax matching global config keys.
      #
      # `:two_factorable` enables account-level MFA policy. Credential models
      # still include Vouch::TwoFactorable independently.
      def authenticates_with(*features, **options)
        feature_concerns = {
          lockable:           "Vouch::Lockable::Concern",
          password_resetable: "Vouch::PasswordResetable::Concern",
          password_trackable: "Vouch::PasswordTrackable::Concern",
          two_factorable:     "Vouch::TwoFactorable::AccountConcern",
          omniauthable:       "Vouch::Omniauthable::Concern",
          invitable:          "Vouch::Invitable::Concern",
          recoverable:        "Vouch::Recoverable"
        }

        requested_concerns = features.map do |feature|
          raise ArgumentError, "Unknown auth feature: #{feature}" unless feature_concerns.key?(feature)

          feature_concerns.fetch(feature)
        end

        self.auth_features = (auth_features + features).uniq.freeze
        self.auth_options = auth_options.deep_merge(options).freeze

        requested_concerns.each do |concern_name|
          include concern_name.constantize if concern_name
        end
      end

      # Read a config value: model override takes precedence over global default.
      #
      # Two-arg form for nested config:
      #   Account.auth_config(:lockable, :max_failed_attempts)  # => 10
      #
      # Single-arg form returns the whole sub-config namespace object:
      #   Account.auth_config(:lockable)  # => LockableConfig instance
      #
      def auth_config(namespace, attribute = nil)
        if attribute
          model_val = auth_options.dig(namespace, attribute)
          return model_val unless model_val.nil?
          Vouch.configuration.send(namespace).send(attribute)
        else
          Vouch.configuration.send(namespace)
        end
      end

      def auth_feature_enabled?(feature)
        auth_features.include?(feature)
      end
    end

    def registration_required?
      self[:registration_required] == true
    end

    def complete_registration!
      Vouch::Persistence.update!(self, registration_required: false) if has_attribute?(:registration_required)
    end

    def auth_config(namespace, attribute = nil)
      self.class.auth_config(namespace, attribute)
    end
  end
end
