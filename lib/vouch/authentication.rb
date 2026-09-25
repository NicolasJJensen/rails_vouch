# frozen_string_literal: true

module Vouch
  module Authentication
    extend ActiveSupport::Concern

    included do
      include Vouch::ControllerHelpers

      helper_method :current_identity, :current_account, :auth_scope_name
      before_action :authenticate_auth_scope!
    end

    class_methods do
      def allow_unauthenticated_access(**options)
        skip_before_action :authenticate_auth_scope!, **options
      end

      def only_allow_unauthenticated_access(**options)
        allow_unauthenticated_access(**options)
        before_action :ensure_auth_scope_signed_out!, **options
      end
    end

    private

    def require_unimpersonated_authentication!
      Vouch::ImpersonationStack.discard_invalid!(warden: warden, session: session)
      head :forbidden if Vouch::ImpersonationStack.active?(session)
    end

    def authenticate_auth_scope!
      return if current_identity

      session[return_to_session_key] = request.fullpath if request.get?
      redirect_to new_session_path
    end

    def ensure_auth_scope_signed_out!
      redirect_to after_sign_in_path if current_identity
    end
  end
end
