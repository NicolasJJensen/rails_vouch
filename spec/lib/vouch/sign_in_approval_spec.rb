require "rails_helper"

RSpec.describe "Approval challenges and proof" do
  let(:account) { create(:account) }
  let(:credential) { account.two_factor_credentials.create!(verified_at: Time.current) }
  def code
    @code
  end

  before do
    allow(credential).to receive(:deliver_two_factor_code) { |value| @code = value }
  end

  it "issues and consumes a distinct challenge without enrolling the credential" do
    token = credential.sign_in_approval_challenge!.token
    expect(credential.verify_sign_in_approval(code, token: token)).to be_ok
    expect(credential.reload.two_factor_enabled_at).to be_nil
    expect(credential.verify_sign_in_approval(code, token: token)).to be_invalid
  end

  it "rejects unverified and locked contacts" do
    credential.update!(verified_at: nil)
    expect(credential.sign_in_approval_challenge).to be_locked
    expect { credential.sign_in_approval_challenge! }.to raise_error(Vouch::OperationFailed)
    credential.update!(verified_at: Time.current, two_factor_locked_at: Time.current)
    expect(credential.sign_in_approval_challenge).to be_locked
  end

  it "rejects unsaved records" do
    expect { TwoFactorCredential.new.sign_in_approval_challenge }.to raise_error(ArgumentError, /unpersisted/)
  end

  it "does not accept an ordinary MFA code as an approval token" do
    credential.enable_two_factor!
    token = credential.challenge!.token
    expect(credential.verify_sign_in_approval(code, token: token)).to be_invalid
  end

  it "does not accept an approval token as an ordinary MFA token" do
    credential.enable_two_factor!
    token = credential.sign_in_approval_challenge!.token
    expect(credential.verify_challenge(code, token: token)).to be_invalid
  end

  it "invalidates the previous challenge on resend" do
    old_token = credential.sign_in_approval_challenge!.token
    old_code = code
    token = credential.sign_in_approval_challenge!.token
    expect(credential.verify_sign_in_approval(old_code, token: old_token)).to be_invalid
    expect(credential.verify_sign_in_approval(code, token: token)).to be_ok
  end

  it "invalidates outstanding challenges when the verified subject changes" do
    token = credential.sign_in_approval_challenge!.token
    credential.update!(otp_secret: ROTP::Base32.random)
    expect(credential.verify_sign_in_approval(code, token: token)).not_to be_ok
  end

  it "locks repeated invalid submissions using the existing MFA limits" do
    token = credential.sign_in_approval_challenge!.token
    account.auth_config(:two_factorable, :max_attempts).times do
      credential.verify_sign_in_approval("invalid", token: token)
    end
    expect(credential.reload).to be_two_factor_locked
    expect(credential.verify_sign_in_approval(code, token: token)).to be_locked
  end

  it "keeps unenrolled approval proof separate from ordinary MFA proof" do
    proof = Vouch::AuthenticationEvidence.build(method: :two_factor, account: account,
      credential: credential, purpose: :sign_in_approval)
    mapping = Vouch.mapping_for(:user)
    expect(Vouch::AuthenticationEvidence.valid?(proof, account: account, mapping: mapping)).to be(true)
    expect(Vouch::AuthenticationEvidence.valid?(proof.except("purpose"), account: account, mapping: mapping)).to be(false)
    credential.update!(otp_secret: ROTP::Base32.random)
    expect(Vouch::AuthenticationEvidence.valid?(proof, account: account, mapping: mapping)).to be(false)
  end

  it "does not accept a credential recovery code as fresh contact proof" do
    credential.enable_two_factor!
    recovery_code = credential.generate_recovery_codes!.value.first
    token = credential.sign_in_approval_challenge!.token
    expect(credential.verify_sign_in_approval(recovery_code, token: token)).to be_invalid
    expect(credential.recovery_codes_remaining).to eq(10)
  end
end
