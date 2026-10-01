# frozen_string_literal: true

class Vouch::TemporaryVerificationsController < Vouch::VerificationsController
  def create(&response_handler)
    return if performed?
    require_temporary_verifiable!
    result = saved_verification_result
    result ||= if @verifiable.valid?(:verification)
      @verifiable.start_verification
    else
      Vouch::Result.invalid(record: @verifiable)
    end
    store_temporary_verification unless result.already_verified?
    respond_to_verification(result, response_handler)
  end

  def update(&response_handler)
    return if performed?
    require_temporary_verifiable!
    result = saved_verification_result || @verifiable.complete_verification(params.require(:code))
    store_temporary_verification unless result.already_verified?
    respond_to_verification(result, response_handler)
  end

  def destroy(&response_handler)
    return if performed?
    require_temporary_verifiable!
    forget_temporary_verification
    respond_to_verification(Vouch::Result.ok(@verifiable), response_handler)
  end

  private

  def restore_temporary_verification(candidate)
    state = temporary_verifications.fetch(params.require(:kind).to_s, {})[candidate.verification_subject_key]
    result = candidate.restore_verification_state(state)
    raise ActiveRecord::RecordNotFound, "Temporary verification was not found or has expired" unless result.ok?

    candidate
  end

  def forget_temporary_verification
    entries = temporary_verifications
    entries.fetch(params.require(:kind).to_s, {}).delete(@verifiable.verification_subject_key)
    session[:vouch_temporary_verifications] = entries
  end

  def store_temporary_verification
    entries = temporary_verifications
    entries[params.require(:kind).to_s] ||= {}
    entries[params.require(:kind).to_s][@verifiable.verification_subject_key] = @verifiable.serialize_verification_state
    session[:vouch_temporary_verifications] = entries
  end

  def temporary_verifications
    session[:vouch_temporary_verifications] || {}
  end

  def require_temporary_verifiable!
    return if @verifiable&.new_record?

    raise Vouch::ConfigurationError, "Build or restore an unsaved @verifiable before temporary verification"
  end

  def saved_verification_result
    unless instance_variable_defined?(:@existing_verifiable)
      raise Vouch::ConfigurationError, "Set @existing_verifiable from the authorized subject lookup, or nil when no record exists"
    end
    return unless @existing_verifiable&.persisted?
    @existing_verifiable.reload
    return unless @existing_verifiable.verified? && @existing_verifiable.verifiable_subject == @verifiable.verifiable_subject

    Vouch::Result.already_verified(@existing_verifiable)
  end
end
