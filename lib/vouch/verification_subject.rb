# frozen_string_literal: true

module Vouch
  module VerificationSubject
    extend ActiveSupport::Concern

    included do
      class_attribute :verifiable_subject_attribute, instance_writer: false
      after_initialize :mark_verifiable_subject_ready
      before_update :synchronize_verification_subject_version
    end

    def verification_subject_values
      canonical_verifiable_subject_attributes.map { |name| public_send(name) }
    end

    def verification_subject_key
      verification_subject_values.to_json
    end

    def verifiable_subject
      attr = self.class.verifiable_subject_attribute
      # Mutable credentials must declare their identifying attributes so
      # subject edits revoke outstanding challenges.
      return id.to_s if !attr && persisted?

      raise NotImplementedError, <<~MSG.squish unless attr
        #{self.class.name} cannot compute a verifiable subject. Declare the
        natural identifier with `self.verifiable_subject_attribute = :your_attr`
        (e.g. :address for Email, :e164 for Phone, :label for Totp).
      MSG

      return public_send(attr).to_s unless attr.is_a?(Array)

      raise ArgumentError, "verification subject attributes cannot be empty" if attr.empty?
      attr.map { |name| [name.to_s, public_send(name)] }.to_json
    end

    private

    def verifiable_subject_version
      has_attribute?(:verification_version) ? self[:verification_version].to_i : 0
    end

    def mark_verifiable_subject_ready
      @verifiable_subject_ready = true
    end

    public
    # `record[:subject] = value` goes through `write_attribute`, while
    # generated setters and `assign_attributes` may call `_write_attribute`
    # directly depending on the Active Record version. Track both entry
    # points while suppressing the nested callback.
    def write_attribute(attr_name, value)
      track_verifiable_subject_write(attr_name, value)
      @verifiable_subject_write_tracked = true
      super
    ensure
      @verifiable_subject_write_tracked = false
    end

    def _write_attribute(attr_name, value)
      track_verifiable_subject_write(attr_name, value) unless @verifiable_subject_write_tracked
      super
    end

    private

    def track_verifiable_subject_write(attr_name, value)
      return if @restoring_verification_state

      subject_attributes = canonical_verifiable_subject_attributes
      return unless @verifiable_subject_ready && subject_attributes.any?
      canonical_attribute = self.class.attribute_aliases[attr_name.to_s] || attr_name.to_s
      return unless subject_attributes.include?(canonical_attribute)
      normalized = self.class.type_for_attribute(canonical_attribute).cast(value)
      return if read_attribute(canonical_attribute) == normalized

      invalidate_verification_for_subject_change!
    end

    def canonical_verifiable_subject_attributes
      Array(self.class.verifiable_subject_attribute).map do |attribute|
        self.class.attribute_aliases[attribute.to_s] || attribute.to_s
      end.uniq
    end

    def invalidate_verification_for_subject_change!
      return if @invalidating_verifiable_subject

      @invalidating_verifiable_subject = true
      self[:verification_version] = verifiable_subject_version + 1 if has_attribute?(:verification_version)
      self[:verified_at] = nil if has_attribute?(:verified_at)
      %i[verification_nonce confirmation_nonce sign_in_nonce two_factor_nonce].each do |attribute|
        self[attribute] = nil if has_attribute?(attribute)
      end
    ensure
      @invalidating_verifiable_subject = false
    end

    # A stale object may be saved concurrently with another subject update.
    # Lock the current row before choosing the next version so both updates
    # advance the persisted counter instead of writing the same N + 1 value.
    def synchronize_verification_subject_version
      return true unless has_attribute?(:verification_version)
      subject_changed = canonical_verifiable_subject_attributes.any? { |name| will_save_change_to_attribute?(name) }
      version_changed = will_save_change_to_attribute?(:verification_version)
      return true unless subject_changed || version_changed

      database_version = attribute_in_database(:verification_version).to_i
      local_delta = [self[:verification_version].to_i - database_version, 1].max
      latest_version = Vouch::RecordKey.find(self.class.lock, Vouch::RecordKey.serialize(self)).verification_version.to_i
      self[:verification_version] = latest_version + local_delta
      self[:verified_at] = nil if subject_changed
      true
    end
  end
end
