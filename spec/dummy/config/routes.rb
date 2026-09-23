# frozen_string_literal: true

Rails.application.routes.draw do
  Vouch.routes(self) do |auth|
    auth.scope :user, account: "Account", identity: "User", tenant: "Organisation" do |auth|
      auth.sessions
      auth.registrations
      auth.passwords
      auth.two_factor
      auth.invitations
      auth.impersonation
      auth.oauth_callbacks
    end
  end

  root "rails/health#show"
end
