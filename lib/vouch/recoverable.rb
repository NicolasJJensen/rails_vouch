# frozen_string_literal: true

require_relative "persistence"
require_relative "recovery_code_association"

# Account-owned recovery codes share generation and consumption with
# credential-owned sets. Row locking serializes replacement and consumption.
module Vouch
  module Recoverable
    extend ActiveSupport::Concern
    include Vouch::LockoutCounter
    include Vouch::RecoveryCodeAssociation

    included do
      has_many :vouch_recovery_codes, class_name: "Vouch::RecoveryCode", as: :recoverable
      before_destroy :destroy_default_recovery_codes, unless: -> { self.class.recovery_code_association_name }
    end

    def recovery_locked?
      locked_window_open?(
        locked_at_attr:   :recovery_locked_at,
        lockout_duration: recoverable_value(:lockout_duration)
      )
    end

    def vouch_recovery_codes
      return super unless composite_recovery_key?

      recovery_codes_relation
    end

    def recovery_codes_remaining
      recovery_codes_relation.where(used_at: nil).count
    end

    def recovery_codes_low?
      recovery_codes_remaining < recovery_code_setting(:low_threshold)
    end

    # Generate a fresh set of recovery codes. Deletes any existing rows
    # (used or unused). Returns the plaintext set — caller MUST display
    # them immediately; the gem never reproduces them.
    def generate_recovery_codes(count: recovery_code_setting(:code_count), length: recovery_code_setting(:code_length))
      plaintexts = Vouch::RecoveryCodes.generate(count: count, length: length)
      attributes = {}
      if composite_recovery_key? && !self.class.recovery_code_association_name
        attributes = {recoverable_type: recoverable_polymorphic_name, recoverable_key: Vouch::RecordKey.dump(self)}
      end
      result = Vouch::RecoveryCodes.replace!(self, relation: recovery_codes_relation,
        plaintexts: plaintexts, attributes: attributes,
        after_replace: -> { Vouch::Persistence.update!(self, recovery_attempts: 0, recovery_locked_at: nil) })
      return result unless result.ok?
      Vouch::Result.ok(plaintexts)
    rescue Vouch::Persistence::Cancelled => error
      Vouch::Result.cancelled(record: self, error: error)
    end

    # Consume a single recovery code. Returns Result.ok on success (marks
    # `used_at`, clears the attempt counter), Result.invalid on a miss, or
    # Result.locked while the recovery lockout is active.
    #
    # `code` is normalized: ALL whitespace stripped (handles "ab cd-ef 12"
    # pasted from a wrapped email), then hyphens dropped,
    # then upcase. Blank input returns Result.invalid.
    def consume_recovery_code(code)
      return Vouch::Result.locked(record: self) if recovery_locked?

      Vouch::RecoveryCodes.consume!(self, relation: -> { recovery_codes_relation }, submitted: code, eligible: -> { !recovery_locked? },
        on_success: ->(_) { Vouch::Persistence.update!(self, recovery_attempts: 0, recovery_locked_at: nil) },
        on_failure: -> { bump_failed_recovery_attempt! })
    end

    def generate_recovery_codes!(**options)
      result = generate_recovery_codes(**options)
      raise Vouch::OperationFailed, result unless result.ok?
      result
    end

    def consume_recovery_code!(code)
      result = consume_recovery_code(code)
      raise Vouch::OperationFailed, result unless result.ok?
      result
    end

    private

    def recovery_code_setting(attribute)
      respond_to?(:auth_config) ? auth_config(:recovery_codes, attribute) : Vouch.configuration.recovery_codes.public_send(attribute)
    end

    def composite_recovery_key?
      self.class.respond_to?(:composite_primary_key?) && self.class.composite_primary_key?
    end

    def recoverable_polymorphic_name
      self.class.respond_to?(:polymorphic_name) ? self.class.polymorphic_name : self.class.base_class.name
    end

    def recovery_codes_relation
      return configured_recovery_codes(default: :vouch_recovery_codes) if self.class.recovery_code_association_name

      return vouch_recovery_codes unless composite_recovery_key?

      Vouch::RecoveryCode.where(
        recoverable_type: recoverable_polymorphic_name,
        recoverable_key: Vouch::RecordKey.dump(self)
      )
    end

    def destroy_default_recovery_codes
      recovery_codes_relation.each { |code| throw(:abort) unless code.destroy }
    end

    def recoverable_config
      Vouch.configuration.recoverable
    end

    def recoverable_value(attribute)
      if respond_to?(:auth_config)
        auth_config(:recoverable, attribute)
      else
        recoverable_config.public_send(attribute)
      end
    end

    # Recoverable inlines the bump. The outer transaction
    # already holds `lock!` on the host row, so wrapping another `with_lock`
    # via LockoutCounter#bump_lockout_counter! would be redundant.
    def bump_failed_recovery_attempt!
      attributes = {recovery_attempts: recovery_attempts + 1}
      attributes[:recovery_locked_at] = Time.current if attributes[:recovery_attempts] >= recoverable_value(:max_attempts)
      Vouch::Persistence.update!(self, attributes)
    end

  end
end
