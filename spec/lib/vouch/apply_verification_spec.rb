require "rails_helper"

RSpec.describe "Applying verified temporary replacements" do
  let(:target) { PhoneVerification.create!(e164: "+61400000000") }
  let(:draft) { PhoneVerification.new(e164: "+61411111111") }

  def verify(record)
    issued = record.start_verification!
    record.complete_verification!(record.last_delivered_code, token: issued.token)
  end

  it "updates only identifying fields and verification while revoking old challenges" do
    target.issue_sign_in_code!
    verify(draft)

    expect(draft.apply_verification_to(target)).to be_ok
    expect(target.reload.e164).to eq(draft.e164)
    expect(target).to be_verified
    expect(target.sign_in_nonce).to be_nil
    expect(target.verification_version).to be_positive
  end

  it "does not refresh an already verified saved subject" do
    verify(draft)
    draft.apply_verification_to!(target)
    original = target.reload.verified_at

    result = draft.apply_verification_to(target)

    expect(result).to be_already_verified
    expect(result).not_to be_ok
    expect(target.reload.verified_at).to eq(original)
  end

  it "rejects a submitted timestamp without successful verification" do
    draft.verified_at = Time.current

    expect(draft.apply_verification_to(target)).to be_invalid
    expect(target.reload.e164).to eq("+61400000000")
  end

  it "rejects changed identifiers even when the timestamp is copied back" do
    verify(draft)
    time = draft.verified_at
    draft.e164 = "+61422222222"
    draft.verified_at = time

    expect(draft.apply_verification_to(target)).to be_invalid
    expect(target.reload.e164).to eq("+61400000000")
  end

  it "rejects expired proof and another model" do
    verify(draft)
    draft.serialize_verification_state
    travel(Vouch.configuration.pending_authentication_ttl + 1.second) do
      expect(draft.apply_verification_to(target)).to be_invalid
    end
    expect(draft.apply_verification_to(create(:invitation_link))).to be_invalid
  end

  it "applies restored trusted state without accepting request replacement fields" do
    verify(draft)
    restored = PhoneVerification.new
    restored.restore_verification_state!(draft.serialize_verification_state)

    expect(restored.apply_verification_to!(target)).to be_ok
    expect(target.reload).to be_verified
  end

  it "rolls back if a callback changes the proof-bound subject" do
    verify(draft)
    callback = -> { self.e164 = "+61433333333" }
    PhoneVerification.before_update(callback)

    expect(draft.apply_verification_to(target)).to be_cancelled
    expect(target.reload.e164).to eq("+61400000000")
    expect(target).not_to be_verified
  ensure
    PhoneVerification.skip_callback(:update, :before, callback) if callback
  end

  it "rolls back when a model callback cancels replacement" do
    verify(draft)
    callback = -> { throw(:abort) }
    PhoneVerification.before_update(callback)

    expect(draft.apply_verification_to(target)).to be_cancelled
    expect(target.reload.e164).to eq("+61400000000")
    expect(target).not_to be_verified
  ensure
    PhoneVerification.skip_callback(:update, :before, callback) if callback
  end
end
