require 'rails_helper'

RSpec.describe 'Host TOTP integration' do
  it 'checks the current locked credential and rejects reuse of an accepted timestep' do
    credential = create(:account).two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    stale = TwoFactorCredential.find(credential.id)
    code = ROTP::TOTP.new(credential.otp_secret).now
    expect(credential.verify_challenge(code, token: :totp)).to be_ok
    expect(stale.verify_challenge(code, token: :totp)).to be_invalid
  end
end
