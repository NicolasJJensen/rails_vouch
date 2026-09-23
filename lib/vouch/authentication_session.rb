# frozen_string_literal: true

module Vouch
  # Owns the authentication-specific session namespace and fixation-safe
  # rotation. It deliberately receives the controller only for Rails session,
  # Warden, and mapping access; authentication decisions remain in the controller concern.
  class AuthenticationSession

    include Rotation
    include Pending
    include OAuthRegistration
    include Invitations

    def initialize(controller)
      @controller = controller
    end

    def key(purpose)
      Vouch::Session.key_for(scope, purpose)
    end

    def dynamic_key(purpose)
      Vouch::Session.dynamic_key_for(scope, purpose)
    end

    def session
      @controller.session
    end

    private

    def controller
      @controller
    end

    def scope
      @controller.send(:auth_scope_name)
    end

    def account_scope
      @controller.send(:account_scope_name)
    end

    def scoped_keys
      [key(:destination_scope), key(:completion), key(:return_to), dynamic_key(Vouch.configuration.credential_drafts_session_suffix), key(:invited_user)]
    end

    def rails_session
      @controller.session
    end

    def warden
      @controller.send(:warden)
    end
  end
end
