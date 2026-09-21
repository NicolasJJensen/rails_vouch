# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Users::Passwords", type: :request do
  let(:account) { create(:account, email_address: "reset@example.com") }
  let!(:user) { create(:user, account: account) }

  describe "GET /users/password/new" do
    it "renders the forgot password form" do
      get "/users/password/new"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /users/password" do
    it "redirects to sign-in with a notice (existing email)" do
      post "/users/password", params: { email_address: "reset@example.com" }
      expect(response).to redirect_to("/users/sign_in")
    end

    it "redirects to sign-in with the same notice (non-existent email)" do
      post "/users/password", params: { email_address: "nobody@example.com" }
      expect(response).to redirect_to("/users/sign_in")
    end

  end

  describe "GET /users/password/edit" do
    it "renders the reset form with a valid token" do
      token = account.generate_password_reset_token!.value
      get "/users/password/edit", params: { token: token }
      expect(response).to have_http_status(:ok)
    end

    it "redirects for an invalid token" do
      get "/users/password/edit", params: { token: "invalid" }
      expect(response).to redirect_to("/users/sign_in")
    end

    it "redirects for array and nested token parameters" do
      get "/users/password/edit", params: { token: ["invalid"] }
      expect(response).to redirect_to("/users/sign_in")

      get "/users/password/edit", params: { token: { nested: "invalid" } }
      expect(response).to redirect_to("/users/sign_in")
    end

    it "redirects for an expired token" do
      token = account.generate_password_reset_token!.value
      travel 20.minutes do
        get "/users/password/edit", params: { token: token }
        expect(response).to redirect_to("/users/sign_in")
      end
    end
  end

  describe "PATCH /users/password" do
    it "updates the password with a valid token" do
      token = account.generate_password_reset_token!.value
      patch "/users/password", params: {
        token: token,
        account: { password: "newpassword1", password_confirmation: "newpassword1" }
      }
      expect(response).to redirect_to("/users/sign_in")
      expect(account.reload.authenticate("newpassword1")).to be_truthy
    end

    it "redirects for an invalid token" do
      patch "/users/password", params: {
        token: "invalid",
        account: { password: "newpassword1", password_confirmation: "newpassword1" }
      }
      expect(response).to redirect_to("/users/sign_in")
    end

    it "rejects array and nested token parameters without changing the password or consuming a token" do
      token = account.generate_password_reset_token!.value
      original_digest = account.password_digest

      [["invalid"], { nested: "invalid" }].each do |invalid_token|
        patch "/users/password", params: {
          token: invalid_token,
          account: { password: "newpassword1", password_confirmation: "newpassword1" }
        }

        expect(response).to redirect_to("/users/sign_in")
        expect(account.reload.password_digest).to eq(original_digest)
        expect(Account.find_by_auth_password_reset_token(token)).to eq(account)
      end
    end

    it "re-renders on mismatched passwords" do
      token = account.generate_password_reset_token!.value
      patch "/users/password", params: {
        token: token,
        account: { password: "newpassword1", password_confirmation: "different" }
      }
      expect(response).to have_http_status(422)
    end
  end
end
