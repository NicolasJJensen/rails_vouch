class Vouch::PasswordResetsController < ::ApplicationController
  include Vouch::Authentication

  only_allow_unauthenticated_access
  before_action :set_account, only: %i[create edit update]

  def new; end

  def create
    return if performed?

    set_operation_result(issue_password_reset)
  end

  def edit
    return if performed?

    set_operation_result(@vouch_account ? Vouch::Result.ok(@vouch_account) : Vouch::Result.invalid)
  end

  def update
    return if performed?

    result = replace_password
    run_hooks(:password_change, @vouch_account) if result.ok?
    if !result.ok? && @vouch_account && @vouch_account.errors.empty?
      @vouch_account.errors.add(:base, I18n.t("vouch.passwords.invalid_token"))
    end
    set_operation_result(result)
  end

  private

  def default_render
    return if performed?
    return super unless @_vouch_operation_result

    case action_name
    when "create"
      redirect_to new_session_path, notice: I18n.t("vouch.passwords.reset_sent")
    when "edit"
      @vouch_account ? super : redirect_to(new_session_path, alert: I18n.t("vouch.passwords.invalid_token"))
    when "update"
      if @operation_status == :ok
        redirect_to new_session_path, notice: I18n.t("vouch.passwords.password_updated")
      elsif @vouch_account
        render :edit, status: :unprocessable_entity
      else
        redirect_to new_session_path, alert: I18n.t("vouch.passwords.invalid_token")
      end
    else
      super
    end
  end

  def replace_password
    return Vouch::Result.invalid unless @vouch_account

    Vouch::Persistence.transaction(@vouch_account) do
      @vouch_account.lock!
      if password_reset_accounts.where(Vouch::RecordKey.attributes_for(@vouch_account)).exists?
        @vouch_account.reset_password_with_token!(params[:token], **password_params.to_h.symbolize_keys)
      else
        @vouch_account = nil
        Vouch::Result.invalid
      end
    end
  rescue Vouch::OperationFailed => error
    error.result
  rescue Vouch::Persistence::Cancelled => error
    Vouch::Result.cancelled(record: @vouch_account, error: error)
  end

  def issue_password_reset
    result = Vouch::Result.invalid
    recipient = nil
    if @vouch_account
      result = Vouch::Persistence.transaction(@vouch_account) do
        @vouch_account.lock!
        if password_reset_accounts.where(Vouch::RecordKey.attributes_for(@vouch_account)).exists?
          recipient = password_reset_recipient
          recipient.present? ? @vouch_account.generate_password_reset_token! : Vouch::Result.invalid
        else
          Vouch::Result.invalid
        end
      end
      if result.ok?
        run_hooks(:password_reset_token_generation, @vouch_account, result.value, recipient)
      elsif result.error
        Rails.error.report(result.error, handled: true)
      end
    end
    result
  rescue Vouch::OperationFailed => error
    Rails.error.report(error.result.error, handled: true) if error.result.error
    error.result
  rescue Vouch::Persistence::Cancelled, *password_reset_delivery_errors => error
    Rails.error.report(error, handled: true)
    Vouch::Result.cancelled(record: @vouch_account, error: error)
  end

  def password_reset_delivery_errors
    errors = [IOError, SystemCallError]
    errors << ActiveJob::EnqueueError if defined?(ActiveJob::EnqueueError)
    errors << Net::SMTPError if defined?(Net::SMTPError)
    errors << Timeout::Error if defined?(Timeout::Error)
    errors << SocketError if defined?(SocketError)
    errors
  end

  def password_reset_accounts
    account_class = auth_mapping.account_class
    accounts = account_class.where.not(password_digest: nil)
    invitations_enabled = Vouch.each_mapping.any? do |mapping|
      mapping.account_class == account_class && mapping.identity_class.include?(Vouch::Invitable::Concern)
    end
    invitations_enabled ? accounts.where(registration_required: false) : accounts
  end

  def set_account
    candidate = if action_name == "create"
      auth_mapping.account_class.first_by_auth_conditions(password_reset_params.to_h.with_indifferent_access)
    else
      auth_mapping.account_class.find_by_auth_password_reset_token(params[:token])
    end
    return unless candidate.is_a?(auth_mapping.account_class) && candidate.persisted?
    @vouch_account = password_reset_accounts.find_by(Vouch::RecordKey.attributes_for(candidate))
    expose_authentication_records
  end

  def password_reset_params
    source = params[auth_mapping.account_param_key] || params
    source.is_a?(ActionController::Parameters) ? source.permit(:email_address, :email, :login) : ActionController::Parameters.new
  end

  def password_reset_recipient
    @vouch_account.email_address
  end

  def password_params
    params.require(auth_mapping.account_param_key).permit(:password, :password_confirmation)
  end
end
