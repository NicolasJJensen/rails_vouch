# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::AuthenticationEvidence do
  let(:account) { create(:account) }
  let(:credential) do
    account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random, verified_at: Time.current,
      two_factor_enabled_at: Time.current)
  end
  let(:mapping) { Vouch.mapping_for(:user) }

  it "refreshes one credential while preserving another credential's proof" do
    first = described_class.build(method: :two_factor, account: account, credential: credential)
    other = account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random, verified_at: Time.current,
      two_factor_enabled_at: Time.current)
    second = described_class.build(method: :two_factor, account: account, credential: other)
    proofs = described_class.record([first], second, account: account, mapping: mapping)
    travel 1.minute do
      refresh = described_class.build(method: :two_factor, account: account, credential: credential, owner: credential)
      expect(described_class.record(proofs, refresh, account: account, mapping: mapping)).to eq([second, refresh])
    end
  end

  it "excludes invalidated factors and proof belonging to another account" do
    proof = described_class.build(method: :two_factor, account: account, credential: credential)
    expect(described_class.current([proof], account: create(:account), mapping: mapping)).to be_empty
    credential.update!(verified_at: nil)
    expect(described_class.current([proof], account: account, mapping: mapping)).to be_empty
  end

  it "retains recovery as a separate proof instead of claiming use of the lost factor" do
    ordinary = described_class.build(method: :two_factor, account: account, credential: credential)
    recovery = described_class.build(method: :recovery_code, account: account, owner: credential)
    expect(described_class.record([ordinary], recovery, account: account, mapping: mapping)).to eq([ordinary, recovery])
    expect(recovery).not_to have_key("credential_type")
  end

  it "rejects an evidence record when its factor was disabled after verification" do
    evidence = described_class.build(method: :two_factor, account: account, credential: credential)
    expect(described_class.valid?(evidence, account: account, mapping: mapping)).to be(true)

    credential.update!(two_factor_enabled_at: nil)
    expect(described_class.valid?(evidence, account: account, mapping: mapping)).to be(false)
  end

  it "does not revive old evidence when a factor is enabled again" do
    evidence = described_class.build(method: :two_factor, account: account, credential: credential)
    credential.disable_two_factor!
    travel 1.second do
      credential.enable_two_factor!
      expect(described_class.valid?(evidence, account: account, mapping: mapping)).to be(false)
      fresh = described_class.build(method: :two_factor, account: account, credential: credential)
      expect(described_class.valid?(fresh, account: account, mapping: mapping)).to be(true)
    end
  end

  it "rejects first-factor and contact verification entries" do
    %i[password oauth verification].each do |method|
      proof = described_class.build(method: method, account: account)
      expect(described_class.current([proof], account: account, mapping: mapping)).to be_empty
    end
  end

  it "rejects evidence from the future" do
    evidence = described_class.build(method: :two_factor, account: account, credential: credential, verified_at: 1.minute.from_now)
    expect(described_class.valid?(evidence, account: account, mapping: mapping)).to be(false)
  end

  it "does not infer a recovery-code proof from an adapter result payload" do
    expect(Vouch::Result.ok({provider: "custom"})).not_to be_recovery_code
    expect(Vouch::Result.ok(:row, recovery_code: true)).to be_recovery_code
  end
end
