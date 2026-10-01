# frozen_string_literal: true

Rails.application.routes.draw do
  resource :phone_sign_in, controller: "users/phone_sessions", only: [:new, :create, :show, :update]
  post "/users/auth/:provider", to: "oauth_requests#create"
  Vouch.routes(self) do |auth|
    auth.scope :user, account: "Account", identity: "User", tenant: "Organisation" do |auth|
      auth.sessions
      auth.registrations
      auth.password_resets
      auth.two_factor
      auth.invitations
      auth.impersonation
      auth.oauth_callbacks registration: :automatic
    end
  end

  root "rails/health#show"
end
