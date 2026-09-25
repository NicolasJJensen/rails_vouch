# frozen_string_literal: true

module Vouch
  class Verifier
    def initialize(mappings = Vouch.each_mapping.to_a)
      @mappings = mappings
    end

    def verify!
      errors = []
      if @mappings.empty?
        errors << "No Vouch scopes are registered"
      else
        @mappings.each { |mapping| verify_mapping(mapping, errors) }
      end
      raise ConfigurationError, "Vouch verification failed:\n- #{errors.join("\n- ")}" if errors.any?
      true
    end

    private

    def verify_mapping(mapping, errors)
      begin
        mapping.resolve_reflections!
      rescue StandardError => e
        errors << "scope :#{mapping.scope_name}: #{e.message}"
      end
      account = mapping.account_class
      identity = mapping.identity_class
      account_requirements = {}
      if account.respond_to?(:auth_feature_enabled?)
        Vouch::FeatureContracts::ACCOUNT_REQUIRED_COLUMNS.each_key do |feature|
          account_requirements[feature] = Vouch::FeatureContracts.account_columns_for(feature, account)
        end
      end
      capture(errors, mapping) { verify_columns(account, account_requirements, errors, mapping) }
      capture(errors, mapping) { verify_account_feature_columns(account, mapping, errors) }
      if account.respond_to?(:auth_feature_enabled?)
        capture(errors, mapping) { verify_feature(account, identity, mapping, :omniauthable, errors) { mapping.oauth_identity_association } }
        capture(errors, mapping) { verify_feature(account, identity, mapping, :two_factorable, errors) do
          associations = mapping.two_factor_credential_associations
          Array(associations).each do |reflection|
            verify_credential_contract(reflection, :two_factorable, mapping, errors)
            verify_backup_codes(reflection, mapping, errors) if reflection.klass.ancestors.include?(Vouch::BackupCodable)
          end
          associations
        end }
        %i[verifiable magic_linkable].each do |feature|
          Array(mapping.credential_associations[feature]).each do |reflection|
            capture(errors, mapping) { verify_credential_contract(reflection, feature, mapping, errors) }
          end
        end
        if identity.ancestors.include?(Vouch::Invitable::Concern)
          capture(errors, mapping) { verify_identity_invitable(identity, mapping, errors) }
          capture(errors, mapping) do
            verify_columns(account, { invitations: Vouch::FeatureContracts.account_columns_for(:invitations, account) }, errors, mapping,
              enabled_features: [:invitations])
          end
        end
        capture(errors, mapping) { verify_password_archives(account, mapping, errors) } if account.auth_feature_enabled?(:password_trackable)
        capture(errors, mapping) { verify_recovery_codes(account, mapping, errors) } if account.auth_feature_enabled?(:recoverable)
      end
    rescue StandardError => e
      errors << "scope :#{mapping.scope_name}: #{e.message}"
    end

    def capture(errors, mapping)
      yield
    rescue StandardError => e
      errors << "scope :#{mapping.scope_name}: #{e.message}"
    end

    def verify_columns(account, requirements, errors, mapping, enabled_features: nil)
      requirements.each do |feature, columns|
        enabled = enabled_features&.include?(feature) ||
          (account.respond_to?(:auth_feature_enabled?) && account.auth_feature_enabled?(feature))
        next unless enabled
        columns.each do |column|
          errors << "scope :#{mapping.scope_name}: #{account.name} requires column #{column.inspect} for :#{feature}" unless account.column_names.include?(column.to_s)
        end
      end
    end

    def verify_account_feature_columns(account, mapping, errors)
      return unless account.respond_to?(:auth_feature_enabled?)
      Vouch::FeatureContracts::ACCOUNT_COLUMNS.each do |feature|
        next unless account.auth_feature_enabled?(feature)
        Vouch::FeatureContracts.columns(feature).each do |column|
          unless account.column_names.include?(column.to_s)
            errors << "scope :#{mapping.scope_name}: #{account.name} requires column #{column.inspect} for :#{feature}"
          end
        end
      end
    end

    def verify_feature(account, _identity, mapping, feature, errors)
      return unless account.auth_feature_enabled?(feature)
      resolved = yield
      errors << "scope :#{mapping.scope_name}: #{account.name} has :#{feature} enabled but no compatible association" if resolved.nil? || (resolved.respond_to?(:empty?) && resolved.empty?)
    end

    def verify_identity_invitable(identity, mapping, errors)
      required = %w[invitation_token invitation_sent_at invitation_accepted_at inviter_id]
      required.each do |column|
        errors << "scope :#{mapping.scope_name}: #{identity.name} requires column #{column.inspect} for invitations" unless identity.column_names.include?(column)
      end
      unless identity.reflect_on_all_associations(:belongs_to).any? { |reflection| reflection.name == :inviter }
        errors << "scope :#{mapping.scope_name}: #{identity.name} requires belongs_to :inviter for invitations"
      end
    end

    def verify_password_archives(account, mapping, errors)
      reflection = account.password_archive_reflection
      verify_required_columns(reflection.klass, %w[password_digest created_at], :password_trackable, mapping, errors)
    end

    def verify_backup_codes(reflection, mapping, errors)
      association = reflection.klass.reflect_on_association(:backup_codes)
      unless association
        errors << "scope :#{mapping.scope_name}: #{reflection.klass.name} requires has_many :backup_codes"
        return
      end
      verify_required_columns(association.klass, %w[code_digest used_at], :backup_codable, mapping, errors)
    end

    def verify_recovery_codes(account, mapping, errors)
      reflection = account.reflect_on_association(:vouch_recovery_codes)
      unless reflection
        errors << "scope :#{mapping.scope_name}: #{account.name} requires has_many :vouch_recovery_codes for :recoverable"
        return
      end
      required = %w[recoverable_type code_digest used_at]
      required << (account.composite_primary_key? ? "recoverable_key" : "recoverable_id") if account.respond_to?(:composite_primary_key?)
      verify_required_columns(reflection.klass, required, :recoverable, mapping, errors)
    end

    def verify_required_columns(record, columns, feature, mapping, errors)
      columns.each do |column|
        unless record.column_names.include?(column.to_s)
          errors << "scope :#{mapping.scope_name}: #{record.name} requires column #{column.inspect} for :#{feature}"
        end
      end
    end

    def verify_credential_contract(reflection, feature, mapping, errors)
      klass = reflection.klass
      Vouch::FeatureContracts.columns_for(feature, klass).each do |column|
        errors << "scope :#{mapping.scope_name}: #{klass.name} requires column #{column.inspect} for :#{feature}" unless klass.column_names.include?(column.to_s)
      end
      method = Vouch::FeatureContracts.delivery_method(feature)
      if klass.instance_method(method).owner == Vouch.const_get(feature.to_s.camelize)
        errors << "scope :#{mapping.scope_name}: #{klass.name} must override ##{method}(code)"
      end
      configured = Vouch::FeatureContracts.configured_attribute(feature, klass)
      if feature.to_sym == :verifiable && klass.respond_to?(:verifiable_subject_attribute)
        if configured.blank?
          errors << "scope :#{mapping.scope_name}: #{klass.name} must configure verifiable_subject_attribute"
        else
          Array(configured).each do |attribute|
            unless attribute_available?(klass, attribute)
              errors << "scope :#{mapping.scope_name}: #{klass.name} requires configured subject attribute #{attribute.inspect} for :verifiable"
            end
          end
        end
      elsif feature.to_sym == :two_factorable && klass.respond_to?(:two_factor_label_attribute) && configured.blank? && !klass.respond_to?(:verifiable_subject_attribute)
        errors << "scope :#{mapping.scope_name}: #{klass.name} must configure two_factor_label_attribute"
      elsif feature.to_sym == :two_factorable && klass.respond_to?(:two_factor_label_attribute) && configured.present? && !attribute_available?(klass, configured)
        errors << "scope :#{mapping.scope_name}: #{klass.name} requires configured label attribute #{configured.inspect} for :two_factorable"
      end
    rescue NameError
      errors << "scope :#{mapping.scope_name}: #{klass.name} does not implement ##{method}(code) for :#{feature}"
    end

    def attribute_available?(klass, attribute)
      klass.column_names.include?(attribute.to_s) || klass.public_instance_methods.include?(attribute.to_sym)
    end
  end
end
