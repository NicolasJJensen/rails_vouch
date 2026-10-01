# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Registration sign-in methods", type: :request do
  it "does not complete ordinary registration without a sign-in method" do
    expect do
      post "/users/sign_up", params: { account: { email_address: "no-login@example.test" } }
    end.not_to change(Account, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(controller.view_assigns.fetch("account").errors[:base]).not_to be_empty
  end

  it "does not silently ignore an explicitly empty password" do
    post "/users/sign_up", params: { account: { email_address: "empty-password@example.test", password: "" } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(controller.view_assigns.fetch("account").errors[:password]).not_to be_empty
  end

  it "identifies invited registration and reuses its tenant" do
    invitee = create(:user, :invited,
      account: create(:account, registration_required: true), invitation_sent_at: Time.current)
    get "/users/invitation/accept", params: { token: invitee.invitation_token }
    get "/users/sign_up"
    expect(controller.send(:invitation_registration?)).to be(true)

    expect do
      post "/users/sign_up", params: { account: {
        password: "replacement-password", password_confirmation: "replacement-password"
      }, organisation: { name: "Ignored tenant" } }
    end.not_to change(Organisation, :count)

    expect(response).to redirect_to("/")
    expect(invitee.reload.invitation_accepted_at).to be_present
  end
end
