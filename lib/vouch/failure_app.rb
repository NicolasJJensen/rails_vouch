# frozen_string_literal: true

# Scope-aware Warden failure handler.
#
# When authentication fails or a strategy throws with an action,
# Warden calls this Rack app. It reads the scope and action from the
# Warden env and redirects accordingly:
#
#   location: "/path"               -> redirect to that path (strategy-supplied)
#   action: "two_factor_challenges" -> 2FA challenge page
#   (default)                       -> sign-in page with flash alert
#
module Vouch
  class FailureApp < ActionController::Metal
    include ActionController::Redirecting
    include ActionController::Flash

    def self.call(env)
      # Lazily include route helpers on first call (Rails.application exists by now).
      unless @_routes_included
        include Rails.application.routes.url_helpers
        @_routes_included = true
      end
      action(:respond).call(env)
    end

    def respond
      scope   = warden_options[:scope] || default_scope
      mapping = Vouch.mapping_for(scope)

      flash[:alert] = warden_message.presence || I18n.t("vouch.failure.unauthenticated")

      if (location = warden_options[:location]).present?
        redirect_to location
      else
        redirect_to mapping.failure_path_for(warden_options[:action], self)
      end
    end

    private

    def warden_options
      request.env["warden.options"] || {}
    end

    def warden_message
      warden_options[:message]
    end

    def default_scope
      Vouch.each_mapping.first&.scope_name || :user
    end
  end
end
