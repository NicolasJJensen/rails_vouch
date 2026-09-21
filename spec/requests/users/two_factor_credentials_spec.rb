# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Users::TwoFactorCredentials", type: :request do
  let(:organisation) { create(:organisation) }
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, organisation: organisation) }

  describe "GET /users/two_factor_credentials" do
    it "requires authentication" do
      get "/users/two_factor_credentials"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "lists credentials when authenticated" do
      sign_in(user)
      get "/users/two_factor_credentials"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /users/two_factor_credentials/new" do
    it "requires authentication" do
      get "/users/two_factor_credentials/new"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "renders the new form when authenticated" do
      sign_in(user)
      get "/users/two_factor_credentials/new"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /users/two_factor_credentials" do
    it "requires authentication" do
      post "/users/two_factor_credentials", params: {
        two_factor_credential: { enabled: true }
      }
      expect(response).to redirect_to("/users/sign_in")
    end

    it "creates a credential when authenticated" do
      sign_in(user)

      expect {
        post "/users/two_factor_credentials", params: {
          two_factor_credential: { enabled: true }
        }
      }.to change(TwoFactorCredential, :count).by(1)

      expect(response).to redirect_to("/users/two_factor_credentials")
    end
  end

  describe "DELETE /users/two_factor_credentials/:id" do
    it "requires authentication" do
      credential = account.two_factor_credentials.create!(otp_secret: SecureRandom.hex(20), enabled: true)
      delete "/users/two_factor_credentials/#{credential.id}"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "deletes the credential when authenticated" do
      sign_in(user)
      credential = account.two_factor_credentials.create!(otp_secret: SecureRandom.hex(20), enabled: true)

      expect {
        delete "/users/two_factor_credentials/#{credential.id}"
      }.to change(TwoFactorCredential, :count).by(-1)

      expect(response).to redirect_to("/users/two_factor_credentials")
    end

    it "redirects with alert for non-existent credential" do
      sign_in(user)
      delete "/users/two_factor_credentials/999999"
      expect(response).to redirect_to("/users/two_factor_credentials")
      expect(flash[:alert]).to eq("2FA method not found.")
    end
  end
end
