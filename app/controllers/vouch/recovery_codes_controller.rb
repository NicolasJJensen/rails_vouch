# frozen_string_literal: true

class Vouch::RecoveryCodesController < ::ApplicationController
  include Vouch::Authentication
  before_action :set_recovery_owner

  def show
    @remaining_recovery_codes = @recovery_owner.recovery_codes_remaining
  end

  def create
    return if performed?

    result = @recovery_owner.generate_recovery_codes
    @remaining_recovery_codes = @recovery_owner.recovery_codes_remaining
    @recovery_codes = result.value if result.ok?
    set_operation_result(result)
  end

  private

  def default_render
    return if performed?
    return super unless action_name == "create" && @_vouch_operation_result

    if @operation_status == :ok
      render :show, status: :created
    else
      record = @_vouch_operation_result.metadata[:record] || @recovery_owner
      flash.now[:alert] = record.errors.full_messages.to_sentence.presence || I18n.t("vouch.recovery_codes.generation_failed")
      render :show, status: :unprocessable_entity
    end
  end

  def set_recovery_owner
    @vouch_account = current_account
    expose_authentication_records
    @recovery_owner = select_recovery_owner(recovery_owners, account: @vouch_account,
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
