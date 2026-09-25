# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::AuthenticationEvidence do
  let(:account) { create(:account) }
  let(:credential) do
    account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random, verified_at: Time.current,
      two_factor_enabled_at: Time.current)
  end
  let(:mapping) { Vouch.mapping_for(:user) }
  let(:requirements) { {credential_types: ["TwoFactorCredential"], max_age: 10.minutes, allow_recovery_codes: false} }

  it "rejects an evidence record when its factor was disabled after verification" do
    evidence = described_class.build(method: :two_factor, account: account, credential: credential)
    expect(described_class.qualifies?(evidence, requirements, account: account, mapping: mapping)).to be(true)

    credential.update!(two_factor_enabled_at: nil)
    expect(described_class.qualifies?(evidence, requirements, account: account, mapping: mapping)).to be(false)
  end

  it "records recovery-code proof separately and lets policy reject it" do
    evidence = described_class.build(method: :recovery_code, account: account, owner: account)
    expect(described_class.qualifies?(evidence, requirements, account: account, mapping: mapping)).to be(false)
  end

  it "does not let a valid factor satisfy a different credential type requirement" do
    evidence = described_class.build(method: :two_factor, account: account, credential: credential)
    expect(described_class.qualifies?(evidence, {credential_types: ["EmailCredential"]}, account: account, mapping: mapping)).to be(false)
  end

  it "can require a specific method when credentials share one Ruby class" do
    credential.define_singleton_method(:authentication_method) { :sms }
    evidence = described_class.build(method: :two_factor, account: account, credential: credential)
    expect(described_class.qualifies?(evidence, {credential_methods: [:totp]}, account: account, mapping: mapping)).to be(false)
  end

  it "rechecks a tightened freshness requirement" do
    evidence = described_class.build(method: :two_factor, account: account, credential: credential, verified_at: 20.minutes.ago)
    expect(described_class.qualifies?(evidence, {credential_types: ["TwoFactorCredential"], max_age: 15.minutes}, account: account, mapping: mapping)).to be(false)
  end

  it "rejects evidence from the future" do
    evidence = described_class.build(method: :two_factor, account: account, credential: credential, verified_at: 1.minute.from_now)
    expect(described_class.qualifies?(evidence, requirements, account: account, mapping: mapping)).to be(false)
  end

  it "does not infer a recovery-code proof from an adapter result payload" do
    expect(Vouch::Result.ok({provider: "custom"})).not_to be_recovery_code
    expect(Vouch::Result.ok(:row, recovery_code: true)).to be_recovery_code
  end
end
