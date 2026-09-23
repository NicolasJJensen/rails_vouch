# Manage 2FA methods for the authenticated user's account.
#
# GET    /users/two_factor_credentials         - list methods
# GET    /users/two_factor_credentials/new      - setup new method
# POST   /users/two_factor_credentials          - create method
# DELETE /users/two_factor_credentials/:id      - remove method
#
class Vouch::TwoFactorCredentialsController < ::ApplicationController
  include Vouch::Authentication

  def index
    @credentials = two_factor_credentials_for(current_account)
  end

  def new
    @credential = two_factor_credentials_for(current_account).new(type: credential_type)
  end

  def create
    @credential = two_factor_credentials_for(current_account).new(credential_params)

    if @credential.save
      redirect_to two_factor_credentials_path, notice: I18n.t("vouch.two_factor_credentials.added")
    else
      render :new, status: 422
    end
  end

  def destroy
    credential = two_factor_credentials_for(current_account).find(params[:id])
    if credential.destroy
      redirect_to two_factor_credentials_path, notice: I18n.t("vouch.two_factor_credentials.removed")
    else
      redirect_to two_factor_credentials_path, alert: I18n.t("vouch.two_factor_credentials.removal_failed")
    end
  rescue ActiveRecord::RecordNotFound, Vouch::TwoFactorable::LastFactorRemoval
    redirect_to two_factor_credentials_path, alert: I18n.t("vouch.two_factor_credentials.not_found")
  end

  private

  # Override-tag: host-facing — the credential type to create. Host
  # apps that support multiple credential types (Email, Phone, AuthenticatorCode)
  # should override this to validate against their allowed list.
  def credential_type
    params[:type].presence
  end

  def credential_params
    params.require(:two_factor_credential).permit(:type, :phone_number, :enabled).tap do |p|
      p[:type] = credential_type if credential_type
    end
  end
end
