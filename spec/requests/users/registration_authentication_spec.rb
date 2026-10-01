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
end
