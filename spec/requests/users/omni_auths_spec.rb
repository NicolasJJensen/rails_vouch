# frozen_string_literal: true

require "rails_helper"
require "omniauth"

RSpec.describe "Users::OmniAuths", type: :request do
  describe "GET /users/auth/failure" do
    it "redirects to sign-in with alert" do
      get "/users/auth/failure", params: { message: "invalid_credentials" }
      expect(response).to redirect_to("/users/sign_in")
    end
  end

  describe "GET /users/auth/:provider/callback" do
    let(:oauth_hash) do
      OmniAuth::AuthHash.new(
        provider: "google_oauth2",
        uid: "12345",
        info: OmniAuth::AuthHash::InfoHash.new(
          email: "oauth@example.com",
          name: "OAuth User"
        )
      )
    end

    context "with an existing linked identity" do
      it "signs in the existing user" do
        account = create(:account, email_address: "oauth@example.com")
        user = create(:user, account: account)
        OmniAuthIdentity.create!(account: account, provider: "google_oauth2", uid: "12345")

        # Pass omniauth.auth directly in the Rack env
        get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => oauth_hash }
        expect(response).to redirect_to("/")
      end
    end

    context "when signed in (linking a new identity)" do
      it "links the identity to the current account" do
        user = create(:user)
        sign_in(user)

        expect {
          get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => oauth_hash }
        }.to change(OmniAuthIdentity, :count).by(1)

        expect(response).to redirect_to("/")
      end

      it "handles duplicate provider+uid gracefully" do
        user = create(:user)
        sign_in(user)

        # Simulate a race condition: find_by returns nil, but the identity
        # was created by another request before the insert completes
        allow(OmniAuthIdentity).to receive(:find_by)
          .with(provider: "google_oauth2", uid: "12345")
          .and_return(nil)

        OmniAuthIdentity.create!(account: user.account, provider: "google_oauth2", uid: "12345")

        get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => oauth_hash }
        expect(response).to redirect_to("/")
        expect(flash[:alert]).to include("Already linked")
      end
    end

    context "when creating a new account" do
      it "creates an account, user, and organisation" do
        expect {
          get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => oauth_hash }
        }.to change(Account, :count).by(1)
          .and change(User, :count).by(1)
          .and change(Organisation, :count).by(1)

        expect(response).to redirect_to("/")
      end

      it "can defer signup to the host registration form without persisting callback records" do
        allow_any_instance_of(Users::OmniAuthsController).to receive(:oauth_registration_required?).and_return(true)
        counts = [Account.count, User.count, OmniAuthIdentity.count]

        get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => oauth_hash }

        expect(response).to redirect_to("/users/sign_up")
        expect([Account.count, User.count, OmniAuthIdentity.count]).to eq(counts)

        post "/users/sign_up", params: {account: {email_address: "oauth@example.com", password: "password123", password_confirmation: "password123"}}

        expect(response).to redirect_to("/")
        expect(OmniAuthIdentity.find_by(provider: "google_oauth2", uid: "12345")).to be_present
      end

      it "expires a deferred OAuth signup context without accepting provider identity from params" do
        allow_any_instance_of(Users::OmniAuthsController).to receive(:oauth_registration_required?).and_return(true)
        get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => oauth_hash }

        travel Vouch.configuration.pending_authentication_ttl + 1.second do
          post "/users/sign_up", params: {account: {email_address: "restart@example.com", password: "password123", password_confirmation: "password123"}, provider: "google_oauth2", uid: "12345"}
        end

        expect(response).to redirect_to("/users/sign_in")
        expect(OmniAuthIdentity.find_by(provider: "google_oauth2", uid: "12345")).to be_nil
      end

      it "retains a valid deferred OAuth context across registration validation errors" do
        allow_any_instance_of(Users::OmniAuthsController).to receive(:oauth_registration_required?).and_return(true)
        get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => oauth_hash }

        post "/users/sign_up", params: {account: {email_address: "invalid-address", password: "password123", password_confirmation: "password123"}}
        expect(response).to have_http_status(:unprocessable_content)
        expect(OmniAuthIdentity.find_by(provider: "google_oauth2", uid: "12345")).to be_nil

        post "/users/sign_up", params: {account: {email_address: "oauth@example.com", password: "password123", password_confirmation: "password123"}}
        expect(response).to redirect_to("/")
        expect(OmniAuthIdentity.find_by(provider: "google_oauth2", uid: "12345")).to be_present
      end
    end
  end
end
