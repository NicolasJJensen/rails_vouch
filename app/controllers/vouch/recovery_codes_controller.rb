# frozen_string_literal: true

# Authenticated recovery-code management. The current account can replace its
# own set; a credential set can only be replaced through a credential owned by
# that account. Plaintext codes are returned exactly once in @recovery_codes.
class Vouch::RecoveryCodesController < ::ApplicationController
  include Vouch::Authentication

  def show
    @recovery_owner = recovery_owner
    return head(:not_found) unless @recovery_owner

    @remaining_recovery_codes = @recovery_owner&.recovery_codes_remaining
  end

  def create
    @recovery_owner = recovery_owner
    return head(:not_found) unless @recovery_owner

    result = @recovery_owner.generate_recovery_codes!
    if result.ok?
      @recovery_codes = result.value
      @remaining_recovery_codes = @recovery_codes.length
      render :show, status: :created
    else
      redirect_to recovery_codes_path, alert: I18n.t("vouch.two_factor.invalid_code")
    end
  end

  private

  def recovery_owner
    return current_account if params[:recovery_owner_type].to_s.in?(["", "account"]) &&
      current_account.respond_to?(:generate_recovery_codes!)
    return nil unless params[:recovery_owner_type].to_s == "credential"

    two_factor_credentials_for(current_account).find(params[:recovery_owner_id]).tap do |credential|
      return nil unless credential.respond_to?(:generate_recovery_codes!)
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end
end
