# frozen_string_literal: true

module Vouch
  class RegistrationFormError < StandardError
    attr_reader :form, :reason

    def initialize(form = nil, reason: :invalid)
      @form = form
      @reason = reason
      super(form&.errors&.full_messages&.to_sentence.presence || "Registration form #{reason.to_s.humanize.downcase}")
    end
  end

  module RegistrationForms
    extend ActiveSupport::Concern

    included do
      class_attribute :_registration_form_class, instance_writer: false
      helper_method :registration_form if respond_to?(:helper_method)
    end

    class_methods do
      def registration_form(form_class)
        include Vouch::ControllerHelpers unless ancestors.include?(Vouch::ControllerHelpers)
        self._registration_form_class = form_class
      end
    end

    def registration_form
      return @registration_form if @registration_form
      return unless registration_form_class

      @account ||= registration_form_record
      context = session[registration_form_session_key]
      if context
        validate_registration_form_context!(context)
        @registration_form = registration_form_class.deserialize(context.fetch("data"), @account)
      else
        @registration_form = registration_form_class.new(@account)
      end
      @registration_form
    rescue Vouch::OperationFailed => error
      @registration_form_restore_error = error
      @registration_form = registration_form_class.new(@account)
      @registration_form.errors.add(:base, I18n.t("vouch.registrations.invalid_verification"))
      @registration_form
    end

    def save_registration_form
      form = registration_form
      raise Vouch::ConfigurationError, "Declare registration_form on the controller before saving a registration form" unless form

      raise Vouch::RegistrationFormError.new(form, reason: :invalid_verification) if @registration_form_restore_error

      data = form.serialize
      validate_registration_form_data!(data)
      context = session[registration_form_session_key]
      validate_registration_form_context!(context) if context
      candidate = registration_form_context.merge(
        "issued_at" => context ? context.fetch("issued_at") : Time.current.to_f,
        "data" => data
      )
      encoded = ActiveSupport::JSON.encode(candidate)
      return Vouch::Result.invalid(record: @account, form: form, reason: :registration_too_large) if encoded.bytesize > registration_form_byte_limit

      session[registration_form_session_key] = ActiveSupport::JSON.decode(encoded)
      Vouch::Result.ok(form)
    rescue Vouch::RegistrationFormError => error
      Vouch::Result.invalid(record: @account, form: error.form, reason: error.reason, error: error)
    end

    def save_registration_form!
      result = save_registration_form
      raise Vouch::OperationFailed.new(result) unless result.ok?

      result.value
    end

    def clear_registration_form
      session.delete(registration_form_session_key)
      @registration_form = nil
      @registration_form_restore_error = nil
    end

    private

    def registration_form_class
      value = self.class._registration_form_class
      value.is_a?(String) ? value.constantize : value
    end

    def registration_form_record
      if oauth_registration_context?
        raise Vouch::RegistrationFormError.new(reason: :context_changed) unless authentication_session.valid_oauth_registration_context?
        authentication_session.oauth_registration_account
      else
        invitation = pending_invited_identity
        if invitation && invitation_requires_registration?(invitation)
          invitation_account_for(invitation)
        else
          auth_mapping.account_class.new
        end
      end
    end

    def registration_form_session_key
      Vouch::Session.key_for(auth_scope_name, :registration_form)
    end

    def registration_form_context
      {
        "scope" => auth_scope_name.to_s,
        "context_id" => authentication_session.context_id,
        "invitation" => session[invited_user_session_key]&.deep_dup,
        "form_class" => registration_form_class.name,
        "record_class" => @account.class.name,
        "record_id" => @account.persisted? ? Vouch::RecordKey.serialize(@account) : nil
      }
    end

    def validate_registration_form_context!(context)
      expected = registration_form_context
      unless context.is_a?(Hash) && context.slice(*expected.keys) == expected && context.key?("data")
        raise Vouch::RegistrationFormError.new(reason: :context_changed)
      end
      issued_at = context["issued_at"]
      age = Time.current.to_f - issued_at if issued_at.is_a?(Numeric)
      unless age && age >= 0 && age < Vouch.configuration.pending_authentication_ttl.to_f
        raise Vouch::RegistrationFormError.new(reason: :expired)
      end
    end

    def validate_registration_form_data!(value)
      case value
      when Hash
        value.each do |key, item|
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise Vouch::ConfigurationError, "Registration form serialization requires string or symbol hash keys"
          end
          if %w[password password_confirmation password_digest password_hash code otp recovery_code otp_secret secret access_token refresh_token id_token].include?(key.to_s)
            raise Vouch::ConfigurationError, "Registration form serialization must not retain #{key}. Use encrypted verification state for credentials."
          end
          validate_registration_form_data!(item)
        end
      when Array
        value.each { |item| validate_registration_form_data!(item) }
      when String, Numeric, TrueClass, FalseClass, NilClass
        nil
      else
        raise Vouch::ConfigurationError, "Registration forms must serialize JSON data, not #{value.class} objects"
      end
    end

    def registration_form_byte_limit
      2.kilobytes
    end

    def prepare_registration_form(attributes = nil)
      form = registration_form
      return unless form

      form.assign_attributes(attributes) if attributes
      result = save_registration_form
      unless result.ok?
        form.errors.add(:base, I18n.t("vouch.registrations.#{result.metadata.fetch(:reason)}"))
        raise Vouch::RegistrationFormError.new(form, reason: result.metadata.fetch(:reason))
      end
      form
    end

    def persist_registration_record!(record)
      return Vouch::Persistence.save!(record) unless registration_form_class

      form = registration_form
      raise Vouch::RegistrationFormError.new(form) unless form.valid?

      bang = form.respond_to?(:save!)
      saved = bang ? form.save! : form.save
      unless (bang ? saved != false : saved) && record.persisted?
        form.errors.add(:base, I18n.t("vouch.registrations.failed")) if form.errors.empty?
        raise Vouch::RegistrationFormError.new(form, reason: :cancelled)
      end
      true
    end

    def lock_registration_record!(record)
      changed_attributes = record.changes.transform_values(&:last)
      associations = record.class.reflect_on_all_associations.filter_map do |reflection|
        [reflection.name, record.association(reflection.name).target] if record.association_cached?(reflection.name)
      end
      record.reload(lock: true)
      record.assign_attributes(changed_attributes)
      associations.each { |name, target| record.association(name).target = target }
    end

    def registration_form_params
      invitation_registration? ? invited_account_params : account_params
    end

    def registration_form_failure(error)
      form = error.respond_to?(:form) ? error.form : @registration_form
      if form && form.errors.empty?
        messages = error.respond_to?(:record) && error.record ? error.record.errors.full_messages : [error.message]
        messages.each { |message| form.errors.add(:base, message) }
      end
      @account.errors.add(:base, error.message) if @account && @account.errors.empty?
      Vouch::Result.invalid(record: @account, form: form, reason: error.respond_to?(:reason) ? error.reason : :invalid, error: error)
    end
  end
end
