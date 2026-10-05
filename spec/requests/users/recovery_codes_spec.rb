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

    post "/users/recovery_codes", params: {recovery_owner_type: "Account"}

    expect(response).to have_http_status(:created)
    expect(account.reload.recovery_codes_remaining).to eq(10)
    expect(other.reload.consume_recovery_code(other_codes.first)).to be_ok
    expect(account.consume_recovery_code(old.first)).not_to be_ok
  end

  it "replaces only the selected credential's recovery-code set" do
    credential = account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    sibling = account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    old = credential.generate_recovery_codes!.value
    sibling_codes = sibling.generate_recovery_codes!.value
    sign_in(user)

    post "/users/recovery_codes", params: {recovery_owner_type: "TwoFactorCredential", recovery_owner_id: credential.id}

    expect(response).to have_http_status(:created)
    expect(credential.consume_recovery_code(old.first)).not_to be_ok
    expect(sibling.consume_recovery_code(sibling_codes.first)).to be_ok
  end

  it "does not expose another account's credential recovery set" do
    foreign_credential = create(:account).two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    sign_in(user)

    get "/users/recovery_codes", params: {recovery_owner_type: "TwoFactorCredential", recovery_owner_id: foreign_credential.id}
    expect(response).to have_http_status(:not_found)
  end

  it "returns not found for an unavailable recovery-code owner" do
    sign_in(user)

    get "/users/recovery_codes", params: {recovery_owner_type: "TwoFactorCredential", recovery_owner_id: "missing"}
    expect(response).to have_http_status(:not_found)
  end
  it "does not let an account ID select another account" do
    other = create(:account)
    sign_in(user)
    post "/users/recovery_codes", params: { recovery_owner_type: "Account", recovery_owner_id: other.id }
    expect(response).to have_http_status(:not_found)
    expect(account.recovery_codes_remaining).to eq(0)
    expect(other.recovery_codes_remaining).to eq(0)
  end

  it "does not resolve arbitrary submitted Ruby constants" do
    sign_in(user)
    get "/users/recovery_codes", params: { recovery_owner_type: "Kernel", recovery_owner_id: user.id }
    expect(response).to have_http_status(:not_found)
  end

  it "prepares the selected owner before the host authorizes the action" do
    Users::RecoveryCodesController.define_method(:create) do
      raise "owner missing" unless @recovery_owner
      head :forbidden
      super()
    end
    sign_in(user)
    post "/users/recovery_codes"
    expect(response).to have_http_status(:forbidden)
    expect(account.recovery_codes_remaining).to eq(0)
  ensure
    Users::RecoveryCodesController.remove_method(:create)
  end

  it "allows a host to replace the successful generation response" do
    Users::RecoveryCodesController.define_method(:create) do
      status = super()
      render json: { count: @recovery_codes.size }, status: :created if status == :ok
    end
    sign_in(user)
    post "/users/recovery_codes"
    expect(response.parsed_body).to eq("count" => 10)
    expect(account.recovery_codes_remaining).to eq(10)
    expect(response.body).not_to include("<code>")
  ensure
    Users::RecoveryCodesController.remove_method(:create)
  end

  it "shows code-model validation errors without losing the previous set" do
    account.generate_recovery_codes!
    old_ids = account.vouch_recovery_codes.ids
    callback = proc { errors.add(:base, "Code storage is temporarily unavailable") }
    Vouch::RecoveryCode.validate(callback)
    sign_in(user)
    post "/users/recovery_codes"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(flash[:alert]).to eq("Code storage is temporarily unavailable")
    expect(account.vouch_recovery_codes.reload.ids).to match_array(old_ids)
  ensure
    Vouch::RecoveryCode.skip_callback(:validate, :before, callback) if callback
  end

end
