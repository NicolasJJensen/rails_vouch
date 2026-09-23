# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Users::Impersonations", type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_account) do
    create(:account, email_address: "admin@example.com",
           password: "password123", password_confirmation: "password123")
  end
  let!(:admin) { create(:user, account: admin_account, organisation: organisation) }
  let(:target_account) { create(:account) }
  let!(:target_user) { create(:user, account: target_account, organisation: organisation) }

  # Sign in via the real login flow so Warden session state is properly
  # established. The stub-based sign_in helper can't test impersonation
  # because it prevents Warden from storing scoped session data.
  def sign_in_via_login
    post "/users/sign_in", params: { email_address: "admin@example.com", password: "password123" }
  end

  before do
    allow_any_instance_of(Users::ImpersonationsController).to receive(:authorize_impersonation!).and_return(true)
  end

  describe "POST /users/impersonations/:id" do
    it "requires authentication" do
      post "/users/impersonations/#{target_user.id}"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "starts impersonation and redirects to root" do
      sign_in_via_login
      post "/users/impersonations/#{target_user.id}"
      expect(response).to redirect_to("/")
    end

    it "does not publish impersonation when its commit hook rolls back" do
      sign_in_via_login
      original_hooks = Users::ImpersonationsController.__hooks
      Users::ImpersonationsController.after_commit_of_impersonation_start do
        raise ActiveRecord::Rollback
      end

      post "/users/impersonations/#{target_user.id}"

      expect(response).to have_http_status(:forbidden)
      delete "/users/impersonations"
      expect(response).to have_http_status(:unprocessable_entity)
    ensure
      Users::ImpersonationsController.__hooks = original_hooks if original_hooks
    end
  end

  describe "DELETE /users/impersonations" do
    it "requires authentication" do
      delete "/users/impersonations"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "restores the original user after ending impersonation" do
      sign_in_via_login
      post "/users/impersonations/#{target_user.id}"

      delete "/users/impersonations"
      expect(response).to redirect_to("/")

      # Confirm we're still authenticated — a protected endpoint returns 200
      get "/users/two_factor_credentials"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "DELETE /users/impersonations/all" do
    it "requires authentication" do
      delete "/users/impersonations/all"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "restores the original user after ending all impersonations" do
      sign_in_via_login
      post "/users/impersonations/#{target_user.id}"

      delete "/users/impersonations/all"
      expect(response).to redirect_to("/")

      # Confirm we're still authenticated — a protected endpoint returns 200
      get "/users/two_factor_credentials"
      expect(response).to have_http_status(:ok)
    end
  end
end
