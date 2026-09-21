# frozen_string_literal: true

module Vouch
  module FeatureContracts
    COLUMNS = {
      lockable: %i[locked_at failed_attempts consecutive_locks],
      password_resetable: %i[password_reset_token_digest password_reset_sent_at],
      recoverable: %i[recovery_attempts recovery_locked_at],
      verifiable: %i[created_at verified_at verification_attempts verification_locked_at verification_version verification_nonce],
      two_factorable: %i[created_at two_factor_enabled_at two_factor_failed_attempts two_factor_locked_at two_factor_last_used_at two_factor_nonce],
      magic_linkable: %i[created_at sign_in_attempts sign_in_locked_at sign_in_nonce]
    }.freeze

    ACCOUNT_COLUMNS = %i[lockable password_resetable recoverable].freeze

    ACCOUNT_REQUIRED_COLUMNS = {
      two_factorable: %i[two_factor_enabled],
      invitations: %i[registration_required]
    }.freeze

    DELIVERY_METHODS = {
      verifiable: :deliver_verification_code,
      two_factorable: :deliver_two_factor_code,
      magic_linkable: :deliver_sign_in_code
    }.freeze

    def self.columns(feature)
      COLUMNS.fetch(feature.to_sym)
    end

    def self.columns_for(feature, model)
      columns(feature).dup.map(&:to_sym).uniq.freeze
    end

    def self.configured_attribute(feature, model)
      case feature.to_sym
      when :verifiable
        model.verifiable_subject_attribute if model.respond_to?(:verifiable_subject_attribute)
      when :two_factorable
        model.two_factor_label_attribute if model.respond_to?(:two_factor_label_attribute)
      end
    end

    def self.account_columns_for(feature, model)
      columns = ACCOUNT_REQUIRED_COLUMNS.fetch(feature.to_sym).dup
      if feature.to_sym == :two_factorable && model.respond_to?(:two_factor_enabled_attribute)
        columns = [model.two_factor_enabled_attribute]
      end
      columns.compact.map(&:to_sym).uniq.freeze
    end

    def self.delivery_method(feature)
      DELIVERY_METHODS.fetch(feature.to_sym)
    end
  end
end
