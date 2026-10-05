# frozen_string_literal: true

module Vouch
  module ControllerOutcomes
    RESERVED_RECORD_NAMES = %w[
      request response params session headers cookies flash env action_name
      operation_status operation_error failure_reason next_step operation
      registration_committed
      credential credentials verifiable invitation receiving_account
      recovery_owner recovery_owners recovery_codes remaining_recovery_codes
      return_to authentication_context authentication_evidence confirmation_actor
      authentication_session authentication_policy auth_hash oauth_initiation oauth_identity
      completed_invitation_acceptance wrapping_invitation_acceptance registration_required
      enrollment_required recovery_available confirmation_return_path confirmation_scope_name
      resolved_impersonator_scope impersonation_return_path
    ].freeze
    private_constant :RESERVED_RECORD_NAMES

    private

    def set_operation_result(result)
      @_vouch_operation_result = result
      @operation_status = result.status
      @operation_error = result.error
      @failure_reason = result.metadata[:reason]
      @next_step = result.metadata[:next_step]
      @operation = result.metadata[:operation]
      @registration_committed = result.metadata[:committed] if result.metadata.key?(:committed)
      @vouch_identity = result.metadata[:identity] if result.metadata.key?(:identity)
      expose_authentication_records
      @operation_status
    end

    def expose_authentication_records
      return unless respond_to?(:auth_mapping, true)
      return unless %i[@vouch_account @vouch_identity @vouch_identities].any? { |name| instance_variable_defined?(name) }

      mapping = auth_mapping
      identity_name = mapping.scope_name.to_s
      account_name = if mapping.membership_scope?
        mapping.parent_scope_name.to_s
      elsif mapping.split_model?
        mapping.account_class.model_name.param_key
      else
        identity_name
      end

      if mapping.split_model? && account_name == identity_name
        raise Vouch::ConfigurationError,
          "Authentication scope :#{identity_name} conflicts with its credentials record name"
      end

      records = []
      records << [account_name, @vouch_account] if instance_variable_defined?(:@vouch_account)
      if instance_variable_defined?(:@vouch_identity) && (mapping.split_model? || !instance_variable_defined?(:@vouch_account))
        records << [identity_name, @vouch_identity]
      end
      if instance_variable_defined?(:@vouch_identities)
        records << [identity_name.pluralize, @vouch_identities]
      end

      names = records.map(&:first)
      duplicate = names.tally.find { |_name, count| count > 1 }&.first
      if duplicate
        raise Vouch::ConfigurationError, "Authentication record aliases conflict at @#{duplicate}; choose distinct scope names"
      end
      names.each do |name|
        unless name.match?(/\A[a-z][a-z0-9_]*\z/) && !RESERVED_RECORD_NAMES.include?(name) && !name.start_with?("vouch_")
          raise Vouch::ConfigurationError, "Authentication scope cannot expose @#{name} as a record"
        end
      end
      records.each { |name, record| instance_variable_set(:"@#{name}", record) }
    end
  end
end
