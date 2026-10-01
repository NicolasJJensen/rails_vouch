require "rails_helper"

RSpec.describe Vouch::VerificationSubject do
  before do
    stub_const("CombinedContact", Class.new(PhoneVerification) do
      include Vouch::TokenVerifiable::Concern
      normalizes :e164, with: ->(value) { value.strip.downcase }
    end)
  end

  let(:contact) { CombinedContact.create!(e164: "alex@example.com") }

  it "does not revoke challenges when normalization leaves the subject unchanged" do
    challenge = contact.start_verification!
    code = contact.last_delivered_code
    version = contact.verification_version

    contact.e164 = "  ALEX@EXAMPLE.COM  "

    expect(contact.verification_version).to eq(version)
    expect(contact.complete_verification!(code, token: challenge.token)).to be_ok
  end

  it "shares the subject declaration with signed links and clears passwordless proof on changes" do
    token = contact.confirmation_token
    contact.issue_sign_in_code!
    contact.update!(e164: "new@example.com")

    expect(contact.reload.sign_in_nonce).to be_nil
    expect(CombinedContact.consume_token(token)).to be_invalid
  end

  it "clears an outstanding signed-link nonce after code verification" do
    contact.confirmation_token
    challenge = contact.start_verification!
    code = contact.last_delivered_code

    expect(contact.complete_verification!(code, token: challenge.token)).to be_ok
    expect(contact.reload.confirmation_nonce).to be_nil
  end

  it "clears an outstanding code nonce after signed-link verification" do
    contact.start_verification!
    token = contact.confirmation_token

    expect(CombinedContact.consume_token(token)).to be_ok
    expect(contact.reload.verification_nonce).to be_nil
  end

  it "reports saved verification without accepting a replay as fresh proof" do
    challenge = contact.start_verification!
    code = contact.last_delivered_code
    token = contact.confirmation_token
    contact.complete_verification!(code, token: challenge.token)

    result = CombinedContact.consume_token(token)

    expect(result).to be_already_verified
    expect(result).not_to be_ok
    expect(contact.start_verification!).to be_already_verified
  end

  it "does not report another subject as verified through an old signed link" do
    token = contact.confirmation_token
    contact.update!(e164: "replacement@example.com")
    challenge = contact.start_verification!
    contact.complete_verification!(contact.last_delivered_code, token: challenge.token)

    expect(CombinedContact.consume_token(token)).to be_invalid
  end

  it "rechecks saved verification before issuing another challenge from a stale instance" do
    stale = CombinedContact.find(contact.id)
    token = contact.confirmation_token
    CombinedContact.consume_token(token)

    expect(stale.start_verification!).to be_already_verified
    expect(stale.last_delivered_code).to be_nil
  end

  it "invalidates both kinds of proof when verification is revoked" do
    token = contact.confirmation_token
    challenge = contact.start_verification!
    code = contact.last_delivered_code
    contact.unverify!

    expect(CombinedContact.consume_token(token)).to be_invalid
    expect(contact.complete_verification!(code, token: challenge.token)).to be_invalid
  end

  it "uses an unambiguous ordered normalized tuple for session lookup" do
    CombinedContact.verifiable_subject_attribute = [:e164, :sign_in_nonce]
    first = CombinedContact.new(e164: " AB ", sign_in_nonce: "c")
    second = CombinedContact.new(e164: "a", sign_in_nonce: "bc")

    expect(first.verification_subject_values).to eq(["ab", "c"])
    expect(first.verification_subject_key).not_to eq(second.verification_subject_key)
  end
end
