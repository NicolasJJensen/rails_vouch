# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Scoped sign-in parameters", type: :request do
  let!(:user) { create(:user, account: create(:account, email_address: "scoped@example.test", password: "password123")) }

  it "authenticates the mapped credentials model's parameter scope" do
    post "/users/sign_in", params: { account: { email_address: " scoped@example.test ", password: "password123" } }
    expect(response).to redirect_to("/")
    expect(user.account.reload.failed_attempts).to eq(0)
  end

  it "does not use a top-level password to repair invalid scoped credentials" do
    post "/users/sign_in", params: { account: { email_address: "scoped@example.test", password: "wrong" }, password: "password123" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(user.account.reload.failed_attempts).to eq(1)
  end
end
