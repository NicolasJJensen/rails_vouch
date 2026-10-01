require "rails_helper"
require "vouch/verification_state"

RSpec.describe Vouch::VerificationState do
  before do
    stub_const("TemporaryContact", Class.new(PhoneVerification) do
      include Vouch::VerificationState
      attribute :owner_reference, :datetime
      attribute :totp_secret, :string
      attribute :password_digest, :string
      attribute :two_factor_enabled_at, :datetime
    end)
  end

  let(:record) { TemporaryContact.new(e164: "+61412345678") }

  it "restores an unsaved challenge without changing its subject or version" do
    issued = record.start_verification
    code = record.last_delivered_code
    restored = TemporaryContact.new

    expect(restored.restore_verification_state(record.serialize_verification_state)).to be_ok
    expect(restored).to be_new_record
    expect(restored.verification_version).to eq(record.verification_version)
    expect(restored.complete_verification(code, token: issued.token)).to be_ok
  end

  it "restores verified state and failure counters without saving a record" do
    issued = record.start_verification
    record.complete_verification(record.last_delivered_code, token: issued.token)
    record.verification_attempts = 2
    restored = TemporaryContact.new

    expect { restored.restore_verification_state!(record.serialize_verification_state) }.not_to change(PhoneVerification, :count)
    expect(restored).to be_verified
    expect(restored.verification_attempts).to eq(2)
  end

  it "encrypts identifying values instead of exposing plain serialized attributes" do
    state = record.serialize_verification_state

    expect(state).not_to include(record.e164)
    expect(TemporaryContact.new.restore_verification_state(state)).to be_ok
  end

  it "preserves an encrypted enrollment secret without exporting password or activation state" do
    record.totp_secret = "PRIVATE-TOTP-SECRET"
    record.password_digest = "DO-NOT-RETAIN"
    record.two_factor_enabled_at = Time.current
    state = record.serialize_verification_state
    restored = TemporaryContact.new
    restored.restore_verification_state!(state)

    expect(state).not_to include("PRIVATE-TOTP-SECRET")
    expect(restored.totp_secret).to eq("PRIVATE-TOTP-SECRET")
    expect(restored.password_digest).to be_nil
    expect(restored.two_factor_enabled_at).to be_nil
  end

  it "rejects changed serialized proof without modifying the recipient" do
    state = record.serialize_verification_state
    restored = TemporaryContact.new(e164: "+61400000000")

    expect(restored.restore_verification_state(state.reverse)).to be_invalid
    expect(restored.e164).to eq("+61400000000")
    expect(restored).not_to be_verified
  end

  it "does not extend the original expiry when restored state is serialized again" do
    state = record.serialize_verification_state
    travel(Vouch.configuration.pending_authentication_ttl - 1.second) do
      restored = TemporaryContact.new
      restored.restore_verification_state!(state)
      state = restored.serialize_verification_state
    end
    travel(Vouch.configuration.pending_authentication_ttl + 1.second) do
      expect(TemporaryContact.new.restore_verification_state(state)).to be_invalid
    end
  end

  it "does not turn a submitted verified_at value into trusted proof" do
    record.verified_at = Time.current
    restored = TemporaryContact.new
    restored.restore_verification_state!(record.serialize_verification_state)

    expect(restored).not_to be_verified
  end

  it "preserves subsecond owner attributes and subject boundaries" do
    TemporaryContact.verifiable_subject_attribute = [:e164, :owner_reference]
    record.owner_reference = Time.utc(2026, 1, 1, 0, 0, 0, 123456)
    another = TemporaryContact.new(e164: record.e164, owner_reference: Time.utc(2026, 1, 1, 0, 0, 0, 123457))
    restored = TemporaryContact.new
    restored.restore_verification_state!(record.serialize_verification_state)

    expect(restored.owner_reference).to eq(record.owner_reference)
    expect(restored.verification_subject_key).to eq(record.verification_subject_key)
    expect(another.verification_subject_key).not_to eq(record.verification_subject_key)
  end

  it "keeps failed-attempt state across restoration" do
    record.start_verification
    record.complete_verification("wrong")
    restored = TemporaryContact.new
    restored.restore_verification_state!(record.serialize_verification_state)

    expect(restored.verification_attempts).to eq(1)
  end

  it "rejects another model's state" do
    stub_const("OtherTemporaryContact", Class.new(TemporaryContact))

    expect(OtherTemporaryContact.new.restore_verification_state(record.serialize_verification_state)).to be_invalid
  end

  it "does not export or overwrite persisted records" do
    saved = TemporaryContact.create!(e164: "+61400000000")

    expect { saved.serialize_verification_state }.to raise_error(ArgumentError, /unsaved/)
    expect { saved.restore_verification_state(record.serialize_verification_state) }.to raise_error(ArgumentError, /unsaved/)
  end
end
