class Vouch::PasswordsController < ::ApplicationController
  include Vouch::Authentication

  only_allow_unauthenticated_access

  def new; end

  def create
    account = auth_mapping.account_class.first_by_auth_conditions(params.to_unsafe_h.with_indifferent_access)

    if account
      raw_token = account.generate_password_reset_token!
      run_hooks(:password_reset_token_generation, account, raw_token.value) { |env| env.add(raw_token.value) }
    end

    redirect_to new_session_path, notice: I18n.t("vouch.passwords.reset_sent")
  end

  def edit
    @account = auth_mapping.account_class.find_by_auth_password_reset_token(params[:token])

    unless @account
      redirect_to new_session_path, alert: I18n.t("vouch.passwords.invalid_token")
    end
  end

  def update
    @account = auth_mapping.account_class.find_by_auth_password_reset_token(params[:token])

    unless @account
      return redirect_to new_session_path, alert: I18n.t("vouch.passwords.invalid_token")
    end

    if @account.reset_password_with_token!(params[:token], **password_params.to_h.symbolize_keys).ok?
      run_hooks(:password_change, @account)
      redirect_to new_session_path, notice: I18n.t("vouch.passwords.password_updated")
    else
      render :edit, status: 422
    end
  end

  private

  def password_params
    params.require(auth_mapping.account_param_key).permit(:password, :password_confirmation)
  end
end
