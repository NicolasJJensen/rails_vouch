# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Users::Registrations", type: :request do
  describe "GET /users/sign_up" do
    it "renders the registration form" do
      get "/users/sign_up"
      expect(response).to have_http_status(:ok)
    end

    it "redirects authenticated users" do
      user = create(:user)
      sign_in(user)
      get "/users/sign_up"
      expect(response).to redirect_to("/")
    end
  end

  describe "POST /users/sign_up" do
    it "creates an account and user" do
      expect {
        post "/users/sign_up", params: {
          account: {
            email_address: "newuser@example.com",
            password: "password123",
            password_confirmation: "password123"
          }
        }
      }.to change(Account, :count).by(1)
        .and change(User, :count).by(1)
        .and change(Organisation, :count).by(1)
    end

    it "creates an organisation for the new user" do
      post "/users/sign_up", params: {
        account: {
          email_address: "newuser2@example.com",
          password: "password123",
          password_confirmation: "password123"
        }
      }
      expect(Organisation.last.name).to eq("newuser2@example.com's Organisation")
    end

    it "signs in the new user and redirects" do
      post "/users/sign_up", params: {
        account: {
          email_address: "newuser3@example.com",
          password: "password123",
          password_confirmation: "password123"
        }
      }
      expect(response).to redirect_to("/")
    end

    it "re-renders on invalid params" do
      post "/users/sign_up", params: {
        account: {
          email_address: "",
          password: "short",
          password_confirmation: "short"
        }
      }
      expect(response).to have_http_status(422)
    end

    it "accepts an invitation when invited_user_id is in session" do
      organisation = create(:organisation)
      invited_user = create(:user, :invited, account: create(:account, registration_required: true), organisation: organisation, invitation_sent_at: 1.day.ago)

      # Set the invited_user_id in session by going through the accept flow
      get "/users/invitation/accept", params: { token: invited_user.invitation_token }

      post "/users/sign_up", params: {
        account: {
          email_address: "invited@example.com",
          password: "invitation-password123",
          password_confirmation: "invitation-password123"
        }
      }

      expect(invited_user.reload.invitation_token).to be_nil
      expect(invited_user.invitation_accepted_at).to be_present
    end
  end
end
