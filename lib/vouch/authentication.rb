# frozen_string_literal: true

module Vouch
  module Authentication
    extend ActiveSupport::Concern

    included do
      include Vouch::ControllerHelpers

      helper_method :current_identity, :current_account, :auth_scope_name, :oauth_registration?, :invitation_registration?, :vouch_route_path
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

    def current_identity
      Vouch.authenticated_identity(warden, auth_scope_name, controller: self)
    end

    def current_account
      if Vouch::ImpersonationStack.active?(session) && auth_mapping.split_model? && !auth_mapping.membership_scope?
        account = Vouch::ImpersonationStack.retained_account(session)
        return account if account.is_a?(auth_mapping.account_class)
        return nil
      end
      if auth_mapping.membership_scope?
        warden.user(auth_mapping.parent_scope_name)
      else
        pending_select_account || (current_identity && auth_mapping.account_for(current_identity))
      end
    end

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
