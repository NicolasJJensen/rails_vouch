class Vouch::TwoFactorCredentialsController < ::ApplicationController
  include Vouch::Authentication
  before_action :build_credential, only: %i[new create]
  before_action :set_credential, only: %i[update destroy]

  def index
    @credentials = credential_relation
  end

  def new
  end

  def create(&response_handler)
    return if performed?

    result = credential_operation { Vouch::Persistence.save!(@credential) }
    respond_with_authentication_result(result, response_handler) do
      if result.ok?
        redirect_to two_factor_credentials_path, notice: I18n.t("vouch.two_factor_credentials.added")
      else
        render :new, status: :unprocessable_entity
      end
    end
  end

  def destroy(&response_handler)
    return if performed?

    result = credential_operation { Vouch::Persistence.destroy!(@credential) }
    respond_with_authentication_result(result, response_handler) do
      if result.ok?
        redirect_to two_factor_credentials_path, notice: I18n.t("vouch.two_factor_credentials.removed")
      else
        redirect_to two_factor_credentials_path, alert: I18n.t("vouch.two_factor_credentials.removal_failed")
      end
    end
  end

  private

  def build_credential
    @credential = credential_relation.new(action_name == "create" ? credential_params : {})
  end

  def set_credential
    @credential = credential_relation.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to two_factor_credentials_path, alert: I18n.t("vouch.two_factor_credentials.not_found")
  end

  def credential_relation
    two_factor_credentials_for(current_account, exclude_primary: false)
  end

  def credential_operation
    result = Vouch::Persistence.transaction(@credential) { yield }
    result.is_a?(Vouch::Result) ? result : Vouch::Result.ok(@credential)
  rescue Vouch::OperationFailed => error
    error.result
  rescue ActiveRecord::RecordInvalid => error
    Vouch::Result.invalid(record: error.record, error: error)
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordNotDestroyed => error
    raise unless error.record
    Vouch::Result.cancelled(record: error.record, error: error)
  end

  def credential_type
    params[:type].presence
  end

  def credential_params
    params.require(:two_factor_credential).permit(:type, :phone_number, :enabled).tap do |attributes|
      attributes[:type] = credential_type if credential_type
    end
  end
end
