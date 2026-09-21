# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Users::Sessions", type: :request do
  let(:organisation) { create(:organisation) }
  let(:account) { create(:account, email_address: "login@example.com", password: "password123", password_confirmation: "password123") }
  let!(:user) { create(:user, account: account, organisation: organisation) }

  describe "GET /users/sign_in" do
    it "renders the sign-in form" do
      get "/users/sign_in"
      expect(response).to have_http_status(:ok)
    end

    it "redirects authenticated users" do
      sign_in(user)
      get "/users/sign_in"
      expect(response).to redirect_to("/")
    end
  end

  describe "POST /users/sign_in" do
    it "signs in with valid credentials" do
      post "/users/sign_in", params: { email_address: "login@example.com", password: "password123" }
      expect(response).to redirect_to("/")
    end

    it "rejects invalid credentials" do
      post "/users/sign_in", params: { email_address: "login@example.com", password: "wrong" }
      expect(response).to have_http_status(422)
    end

    it "rejects a locked account" do
      account.update!(locked_at: Time.current, failed_attempts: 5)
      post "/users/sign_in", params: { email_address: "login@example.com", password: "password123" }
      expect(response).to have_http_status(422)
    end

    it "calls successful_login! on the account" do
      post "/users/sign_in", params: { email_address: "login@example.com", password: "password123" }
      expect(account.reload.failed_attempts).to eq(0)
    end

    it "increments failed_attempts on failure" do
      post "/users/sign_in", params: { email_address: "login@example.com", password: "wrong" }
      expect(account.reload.failed_attempts).to eq(1)
    end

    context "when account has 2FA enabled" do
      before do
        account.two_factor_credentials.create!(
          otp_secret: SecureRandom.hex(20),
          enabled: true,
          verified_at: Time.current,
          two_factor_enabled_at: Time.current
        )
        account.enable_two_factor!
      end

      it "redirects to the 2FA challenge page" do
        post "/users/sign_in", params: { email_address: "login@example.com", password: "password123" }
        expect(response).to redirect_to("/users/two_factor_challenges")
      end
    end
  end

  describe "DELETE /users/sign_out" do
    it "signs out and redirects to sign-in page" do
      sign_in(user)
      delete "/users/sign_out"
      expect(response).to redirect_to("/users/sign_in")
    end
  end
end
