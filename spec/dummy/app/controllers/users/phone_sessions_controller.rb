class Users::PhoneSessionsController < ApplicationController
  include Vouch::Authentication
  only_allow_unauthenticated_access

  class DeliveryError < StandardError; end

  def new
    render plain: "Choose a phone"
  end

  def create
    session.delete(:phone_sign_in)
    phone = TwoFactorCredential.where.not(verified_at: nil).find(params.require(:credential_id))
    result = phone.issue_sign_in_code
    if result.ok?
      session[:phone_sign_in] = { "id" => phone.id, "token" => result.token }
      redirect_to phone_sign_in_path
    else
      render json: { status: result.status }, status: :unprocessable_entity
    end
  rescue DeliveryError => error
    Rails.error.report(error)
    render json: { status: "delivery_failed" }, status: :service_unavailable
  end

  def show
    return redirect_to new_phone_sign_in_path unless session[:phone_sign_in]
    render plain: "Enter the code"
  end

  def update
    pending = session[:phone_sign_in]
    return redirect_to new_phone_sign_in_path unless pending
    phone = TwoFactorCredential.where.not(verified_at: nil).find(pending.fetch("id"))
    result = phone.verify_sign_in_code(params.require(:code), token: pending.fetch("token"))
    unless result.ok?
      session.delete(:phone_sign_in) if result.locked?
      return render json: { status: result.status }, status: :unprocessable_entity
    end

    session.delete(:phone_sign_in)
    outcome = complete_sign_in(phone.account, method: :passwordless, signed_in_via: phone)
    case outcome
    when :signed_in then redirect_after_authentication
    when :needs_two_factor then redirect_to two_factor_challenges_path
    when :needs_selection then redirect_to select_path
    else redirect_to new_phone_sign_in_path, alert: "Unable to sign in"
    end
  end
end
