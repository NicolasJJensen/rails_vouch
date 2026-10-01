# frozen_string_literal: true

class Vouch::VerificationsController < ::ApplicationController
  rescue_from Vouch::VerificationRateLimitStore::Unavailable do
    head :service_unavailable
  end

  def create(&response_handler)
    return if performed?
    require_persisted_verifiable!
    result = @verifiable.start_verification
    if result.ok?
      tokens = session[:vouch_verification_tokens] || {}
      tokens[verification_record_key] = result.token
      session[:vouch_verification_tokens] = tokens
    end
    respond_to_verification(result, response_handler)
  end

  def update(&response_handler)
    return if performed?
    require_persisted_verifiable!
    tokens = session[:vouch_verification_tokens] || {}
    result = @verifiable.complete_verification(params.require(:code), token: tokens[verification_record_key])
    if result.ok? || result.already_verified?
      tokens.delete(verification_record_key)
      session[:vouch_verification_tokens] = tokens
    end
    respond_to_verification(result, response_handler)
  end

  private

  def verification_subject_key
    [@verifiable.class.base_class.name, @verifiable.verification_subject_key].to_json
  end

  def verification_record_key
    [@verifiable.class.name, Vouch::RecordKey.serialize(@verifiable), @verifiable.verification_subject_key].to_json
  end

  def require_persisted_verifiable!
    return if @verifiable&.persisted?

    raise Vouch::ConfigurationError, "Set @verifiable through an authorized association before verifying an existing record"
  end

  def respond_to_verification(result, response_handler)
    response_handler&.call(result)
    return if performed?

    status = if result.ok? || result.already_verified?
      :ok
    elsif result.locked?
      :too_many_requests
    else
      :unprocessable_entity
    end
    render json: { status: result.status, errors: @verifiable.errors.to_hash }, status: status
  end
end
