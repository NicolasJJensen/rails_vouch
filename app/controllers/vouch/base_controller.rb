class Vouch::BaseController < Vouch.configuration.parent_controller.constantize
  include Vouch::ControllerHelpers

  helper_method :current_identity, :current_account, :auth_scope_name
  before_action :authenticate_auth_scope!

  class << self
    def allow_unauthenticated_access(**options)
      skip_before_action :authenticate_auth_scope!, **options
      Vouch.configuration.authentication_callbacks.each do |callback|
        skip_before_action callback, raise: false, **options
      end
    end

    def only_allow_unauthenticated_access(**options)
      allow_unauthenticated_access(**options)
      before_action :ensure_auth_scope_signed_out!, **options
    end
  end

  private

  def authenticate_auth_scope!
    return if current_identity

    session[return_to_session_key] = request.fullpath if request.get?
    redirect_to new_session_path
  end

  def ensure_auth_scope_signed_out!
    redirect_to after_sign_in_path if current_identity
  end
end
