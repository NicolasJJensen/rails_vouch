# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Users::RecoveryCodes", type: :request do
  let(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }

  it "replaces only the current account's recovery-code set" do
    other = create(:account)
    old = account.generate_recovery_codes!.value
    other_codes = other.generate_recovery_codes!.value
    sign_in(user)

    post "/users/recovery_codes", params: {recovery_owner_type: "account"}

    expect(response).to have_http_status(:created)
    expect(account.reload.recovery_codes_remaining).to eq(10)
    expect(other.reload.consume_recovery_code!(other_codes.first)).to be_ok
    expect(account.consume_recovery_code!(old.first)).not_to be_ok
  end

  it "replaces only the selected credential's recovery-code set" do
    credential = account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    sibling = account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    old = credential.generate_recovery_codes!.value
    sibling_codes = sibling.generate_recovery_codes!.value
    sign_in(user)

    post "/users/recovery_codes", params: {recovery_owner_type: "credential", recovery_owner_id: credential.id}

    expect(response).to have_http_status(:created)
    expect(credential.consume_recovery_code!(old.first)).not_to be_ok
    expect(sibling.consume_recovery_code!(sibling_codes.first)).to be_ok
  end

  it "does not expose another account's credential recovery set" do
    foreign_credential = create(:account).two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    sign_in(user)

    get "/users/recovery_codes", params: {recovery_owner_type: "credential", recovery_owner_id: foreign_credential.id}
    expect(response).to have_http_status(:not_found)
  end

  it "returns not found for an unavailable recovery-code owner" do
    sign_in(user)

    get "/users/recovery_codes", params: {recovery_owner_type: "credential", recovery_owner_id: "missing"}
    expect(response).to have_http_status(:not_found)
  end
end
