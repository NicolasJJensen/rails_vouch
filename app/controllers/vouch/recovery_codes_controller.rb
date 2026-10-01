# frozen_string_literal: true

class Vouch::RecoveryCodesController < ::ApplicationController
  include Vouch::Authentication
  before_action :set_recovery_owner

  def show
    @remaining_recovery_codes = @recovery_owner.recovery_codes_remaining
  end

  def create(&response_handler)
    return if performed?

    result = @recovery_owner.generate_recovery_codes
    @remaining_recovery_codes = @recovery_owner.recovery_codes_remaining
    respond_with_authentication_result(result, response_handler) do
      if result.ok?
        @recovery_codes = result.value
        render :show, status: :created
      else
        record = result.metadata[:record] || @recovery_owner
        flash.now[:alert] = record.errors.full_messages.to_sentence.presence || I18n.t("vouch.recovery_codes.generation_failed")
        render :show, status: :unprocessable_entity
      end
    end
  end

  private

  def set_recovery_owner
    @recovery_owner = select_recovery_owner(recovery_owners, account: current_account,
      type: params[:recovery_owner_type], id: params[:recovery_owner_id])
    head :not_found unless @recovery_owner
  end

  def recovery_owners
    owners = []
    owners << current_account if current_account.respond_to?(:generate_recovery_codes)
    if Array(auth_mapping.two_factor_credential_associations).any?
      owners.concat(two_factor_credentials_for(current_account, exclude_primary: false)
        .select { |credential| credential.respond_to?(:generate_recovery_codes) })
    end
    owners
  end
end
