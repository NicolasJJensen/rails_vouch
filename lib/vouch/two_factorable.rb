# frozen_string_literal: true

# TwoFactorable concern — second-factor verification on any model that
# represents a 2FA method (Email, Phone, host-defined AuthenticatorCode,
# WebauthnCredential). Replaces the old TwoFactorAuthenticatable and
# TwoFactorCredential::Concern modules.
#
# Single invariant: `enable_two_factor!` requires `verified?`.
# 2FA can only be enabled on a verified credential. TOTP enrollment uses
# Verifiable's challenge model — the QR-then-enter-a-code dance fits.
#
# Required columns (added by `bin/rails g vouch:two_factorable`):
#   - two_factor_enabled_at:datetime
#   - two_factor_failed_attempts:bigint default: 0, null: false
#   - two_factor_locked_at:datetime
#   - two_factor_last_used_at:datetime
#   - two_factor_nonce:string (nullable)
#   - created_at:datetime (validated when the feature is used)
#
# Public surface:
#   - #two_factor_enabled?, #two_factor_locked?
#   - #enable_two_factor!                       (raises UnverifiedCredential if not verified)
#   - #disable_two_factor!                      (clears the flag; leaves verified_at intact)
#   - #challenge!                               => Result.ok(token) | Result.locked
#   - #verify_challenge(code, token:)           => Result
#   - #record_two_factor_use!                   (idempotent timestamp bump for hosts to call after sign-in)
#
# Hosts override #deliver_two_factor_code(code) per credential type.
#
module Vouch
  module TwoFactorable
    extend ActiveSupport::Concern
    include Vouch::LockoutCounter
    include Vouch::ChallengeNonce

    TWO_FACTORABLE_CONFIG_KEYS = %i[challenge_validity max_attempts lockout_duration length].freeze

    included do
      scope :enabled, -> { where.not(two_factor_enabled_at: nil) }

      # Class DSL: the attribute displayed in the 2FA picker UI. Defaults
      # to Verifiable's subject attribute when the model also includes
      # Verifiable (Phone → :e164, Totp → :label, Email → :address); host
      # can override for a different display name.
      class_attribute :two_factor_label_attribute, instance_writer: false

      install_two_factor_challenge_wrapper! if ancestors.include?(Vouch::BackupCodable)
    end

    class LastFactorRemoval < StandardError; end

    # Human-readable label for this credential in the 2FA picker. Falls back
    # to verifiable_subject_attribute so hosts that follow the credential
    # pattern get it for free.
    def two_factor_label
      attr = self.class.two_factor_label_attribute
      attr ||= self.class.verifiable_subject_attribute if self.class.respond_to?(:verifiable_subject_attribute)

      raise NotImplementedError, <<~MSG.squish unless attr
        #{self.class.name} needs a display attribute for the 2FA picker.
        Declare it with `self.two_factor_label_attribute = :your_attr`
        (or include Vouch::Verifiable and set
        verifiable_subject_attribute).
      MSG

      public_send(attr).to_s
    end

    def two_factor_enabled?
      two_factor_enabled_at.present?
    end

    def two_factor_locked?
      locked_window_open?(
        locked_at_attr:   :two_factor_locked_at,
        lockout_duration: two_factorable_config.lockout_duration
      )
    end

    # Toggle 2FA on. Requires that the credential has been verified. The
    # verified gate eliminates the "2FA enabled on an
    # unconfirmed channel" bug class.
    def enable_two_factor!
      Vouch::Persistence.transaction(self) do
        lock!

        unless respond_to?(:verified?) && verified?
          raise Vouch::UnverifiedCredential, <<~MSG.squish
            Cannot enable two-factor on #{self.class.name}##{id}: credential
            is not verified. Run start_verification! / complete_verification!
            first.
          MSG
        end

        Vouch::Persistence.update!(self, two_factor_enabled_at: Time.current)
      end

      self
    end

    def disable_two_factor!
      owner = two_factor_account
      if owner
        owner.class.transaction(requires_new: true) do
          owner.lock!
          if owner.respond_to?(:two_factor_enabled?) && owner.two_factor_enabled?
            ensure_not_last_usable_factor!(owner)
          end
          Vouch::Persistence.update!(self, two_factor_enabled_at: nil)
        end
      else
        Vouch::Persistence.transaction(self) { Vouch::Persistence.update!(self, two_factor_enabled_at: nil) }
      end
      self
    end

    # Destroying a credential is also a policy operation. Lock the account
    # before counting factors so concurrent removals cannot leave enabled MFA
    # without a usable factor.
    def destroy
      owner = two_factor_account
      return super unless owner

      destroyed = false
      owner.class.transaction(requires_new: true) do
        owner.lock!
        ensure_not_last_usable_factor!(owner) if owner.respond_to?(:two_factor_enabled?) && owner.two_factor_enabled?
        destroyed = super
        raise ActiveRecord::Rollback unless destroyed
      end
      destroyed
    end

    # Issue a fresh 2FA challenge. Delivery exceptions bubble (decisions
    # 38, 40). Hosts rescue at the controller level.
    def challenge!
      self.class.validate_auth_schema!(*Vouch::FeatureContracts.columns_for(:two_factorable, self.class))
      raise ArgumentError, "cannot challenge an unpersisted record" unless persisted?
      return Vouch::Result.locked if two_factor_locked? || !two_factor_eligible?

      nonce = issue_nonce!(:two_factor_nonce)
      issued = OtpCourier::OTP.issue(
        purpose:  Vouch::Purposes.two_factor(self),
        payload:  two_factor_payload.merge("nonce" => nonce),
        validity: two_factorable_config.challenge_validity,
        length:   two_factorable_config.length
      )

      deliver_two_factor_code(issued.code)

      Vouch::Result.ok(issued.token)
    end

    def verify_challenge(code, token:)
      self.class.validate_auth_schema!(*Vouch::FeatureContracts.columns_for(:two_factorable, self.class))
      return Vouch::Result.locked if two_factor_locked? || !two_factor_eligible?

      # Trim leading and trailing whitespace from copy-paste.
      code = code.to_s.strip

      payload = consume_otp_token(token, code, Vouch::Purposes.two_factor(self))

      if two_factor_payload_valid?(payload)
        transaction_result = Vouch::Persistence.transaction(self) do
          lock!
          next Vouch::Result.invalid if two_factor_locked?
          next Vouch::Result.invalid unless two_factor_eligible?
          next Vouch::Result.invalid unless two_factor_payload_valid?(payload)

          Vouch::Persistence.update!(self,
            two_factor_nonce:          nil,
            two_factor_failed_attempts: 0,
            two_factor_locked_at:       nil,
            two_factor_last_used_at:    Time.current
          )
        end
        transaction_result.is_a?(Vouch::Result) ? transaction_result : Vouch::Result.ok
      else
        bump_lockout_counter!(
          counter_attr:     :two_factor_failed_attempts,
          locked_at_attr:   :two_factor_locked_at,
          max_attempts:     two_factorable_config.max_attempts,
          lockout_duration: two_factorable_config.lockout_duration
        )
        Vouch::Result.invalid
      end
    rescue Vouch::Persistence::Cancelled
      Vouch::Result.cancelled
    end

    # Idempotent timestamp bump. Hosts call this after a successful sign-in
    # that consumed a 2FA factor — gives them a stable hook rather than
    # poking the column directly. Does NOT clear failed-attempt counters
    # (those clear on a successful verify_challenge instead).
    def record_two_factor_use!
      Vouch::Persistence.transaction(self) { Vouch::Persistence.update!(self, two_factor_last_used_at: Time.current) }
      self
    end

    # Host delivery hook. Override per credential type:
    #
    #   def deliver_two_factor_code(code)
    #     AccountMailer.two_factor(self.account, code).deliver_later
    #   end
    #
    def deliver_two_factor_code(_code)
      raise Vouch::ConfigurationError,
        "#{self.class.name} must implement #deliver_two_factor_code(code)"
    end

    private

    def two_factor_account
      owners = self.class.reflect_on_all_associations(:belongs_to).filter_map do |candidate|
        if candidate.polymorphic?
          owner = public_send(candidate.name)
          owner if owner && owner.class.respond_to?(:auth_feature_enabled?) &&
            owner.class.auth_feature_enabled?(:two_factorable)
        else
          owner = public_send(candidate.name)
          owner if candidate.klass.respond_to?(:auth_feature_enabled?) &&
            candidate.klass.auth_feature_enabled?(:two_factorable)
        end
      end
      distinct = owners.uniq { |owner| [owner.class, owner.id] }
      return distinct.first if distinct.length <= 1

      raise Vouch::ConfigurationError, <<~MSG.squish
        #{self.class.name} has multiple distinct two-factor account owners.
        Override #two_factor_account to select the owning account record.
      MSG
    end

    def ensure_not_last_usable_factor!(owner)
      associations = if owner.respond_to?(:two_factor_credential_associations)
        owner.two_factor_credential_associations
      else
        owner.class.reflect_on_all_associations(:has_many).select do |reflection|
          reflection.klass.ancestors.include?(Vouch::TwoFactorable)
        end
      end
      remaining = 0
      target_usable = false
      associations.each do |association|
        association_scope = owner.public_send(association.name)
        association_scope.reset
        association_scope.to_a.each do |credential|
          usable = credential.two_factor_enabled? &&
            (!credential.respond_to?(:verified?) || credential.verified?) &&
            !credential.two_factor_locked?
          if credential.class == self.class && credential.id.to_s == id.to_s
            target_usable = usable
          elsif usable
            remaining += 1
          end
        end
      end
      return unless target_usable && remaining.zero?

      action = if owner.respond_to?(:two_factor_last_factor_removal_action)
        owner.two_factor_last_factor_removal_action(self)
      else
        :prevent
      end
      case action.to_sym
      when :disable
        owner.write_two_factor_enabled!(false)
      when :prevent
        raise Vouch::TwoFactorable::LastFactorRemoval, "cannot remove the last usable two-factor credential"
      else
        raise Vouch::ConfigurationError, "unsupported two-factor last-factor action: #{action.inspect}"
      end
    end

    def two_factor_account_class
      candidates = self.class.reflect_on_all_associations(:belongs_to).filter_map do |reflection|
        if reflection.polymorphic?
          owner_class = public_send(reflection.name)&.class
          owner_class if owner_class && owner_class.respond_to?(:auth_config) &&
            owner_class.respond_to?(:auth_feature_enabled?) &&
            owner_class.auth_feature_enabled?(:two_factorable)
        elsif reflection.klass.respond_to?(:auth_config) &&
              reflection.klass.respond_to?(:auth_feature_enabled?) &&
              reflection.klass.auth_feature_enabled?(:two_factorable)
          reflection.klass
        end
      end.uniq

      return candidates.first if candidates.length <= 1

      raise Vouch::ConfigurationError, <<~MSG.squish
        #{self.class.name} has ambiguous two-factor account owners:
        #{candidates.map(&:name).join(', ')}. Override #two_factor_account_class
        to select the owning account model.
      MSG
    end

    def two_factor_eligible?
      two_factor_enabled? && (!respond_to?(:verified?) || verified?)
    end

    def two_factor_payload
      payload = { "id" => id.to_s, "klass" => self.class.name }
      if respond_to?(:verifiable_subject)
        payload["subject"] = verifiable_subject
        payload["version"] = verifiable_subject_version
      end
      payload
    end

    def two_factor_payload_valid?(payload)
      return false unless payload_valid?(payload) && nonce_matches?(payload, :two_factor_nonce)
      return true unless respond_to?(:verifiable_subject)

      payload["subject"] == verifiable_subject &&
        payload["version"].is_a?(Integer) &&
        payload["version"] == verifiable_subject_version
    end

    def two_factorable_config
      global = Vouch.configuration.two_factorable
      owner = two_factor_account_class
      return global unless owner

      config = global.dup
      TWO_FACTORABLE_CONFIG_KEYS.each do |key|
        config.public_send("#{key}=", owner.auth_config(:two_factorable, key))
      end
      config
    end
  end

  # Account-level MFA policy. This is mixed into the mapped authentication
  # account when :two_factorable is declared; credentials remain independent
  # enrolled factors and may be ready while the account preference is off.
  module TwoFactorable::AccountConcern
    extend ActiveSupport::Concern

    included do
      class_attribute :two_factor_enabled_attribute, instance_writer: false, default: :two_factor_enabled
    end

    def two_factor_enabled?
      return false unless has_attribute?(self.class.two_factor_enabled_attribute)

      public_send(self.class.two_factor_enabled_attribute) == true
    end

    def enable_two_factor!
      self.class.transaction(requires_new: true) do
        lock!
        raise Vouch::ConfigurationError, "cannot enable two-factor without a usable credential" unless usable_two_factor_credentials.any?

        write_two_factor_enabled!(true)
      end
      self
    end

    def disable_two_factor!
      self.class.transaction(requires_new: true) do
        lock!
        write_two_factor_enabled!(false)
      end
      self
    end

    # Hosts may opt into clearing account MFA when the final usable factor is
    # removed. The default keeps MFA enabled and prevents that removal.
    def two_factor_last_factor_removal_action(credential)
      :prevent
    end

    # Host apps with a non-standard account column or persistence layer can
    # override this hook while retaining the account-level API.
    def write_two_factor_enabled!(value)
      Vouch::Persistence.update!(self, self.class.two_factor_enabled_attribute => value)
    end

    def two_factor_credential_associations
      applicable_mappings = []
      Vouch.each_mapping do |mapping|
        next unless mapping_applies_to_account?(mapping)

        associations = Array(mapping.two_factor_credential_associations)
        applicable_mappings << [mapping, associations]
      end

      configured = applicable_mappings.reject { |_, associations| associations.empty? }
      if configured.any?
        normalized = configured.map do |mapping, associations|
          [mapping, associations, associations.map { |reflection| reflection.name.to_sym }.sort]
        end
        expected = normalized.first.last
        unless normalized.all? { |_, _, names| names == expected }
          details = normalized.map do |mapping, _, names|
            ":#{mapping.scope_name} (#{names.join(', ')})"
          end.join('; ')
          raise Vouch::ConfigurationError, <<~MSG.squish
            Conflicting two-factor credential associations for #{self.class.name} across
            authentication scopes: #{details}. Configure matching associations for every
            scope that authenticates this account.
          MSG
        end

        return normalized.first[1].sort_by { |reflection| reflection.name.to_sym }
      end

      return [] if applicable_mappings.any?

      self.class.reflect_on_all_associations(:has_many).select do |reflection|
        reflection.klass.ancestors.include?(Vouch::TwoFactorable)
      end
    rescue ArgumentError
      []
    end

    def mapping_applies_to_account?(mapping)
      mapped_class = mapping.account_class
      self.class == mapped_class || (self.class <= mapped_class)
    end

    private

    def usable_two_factor_credentials
      two_factor_credential_associations.flat_map do |association|
        public_send(association.name).to_a.select do |credential|
          credential.two_factor_enabled? &&
            (!credential.respond_to?(:verified?) || credential.verified?) &&
            !credential.two_factor_locked?
        end
      end
    end
  end
end
