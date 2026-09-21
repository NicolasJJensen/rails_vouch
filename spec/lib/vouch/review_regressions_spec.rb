require 'rails_helper'

RSpec.describe 'Credential review regressions' do
  let(:phone) { PhoneVerification.create!(e164: '+61400000001') }

  it 'R5 rejects a challenge after changing its subject' do
    result = phone.start_verification!
    code = phone.last_delivered_code
    phone.update!(e164: '+61400000002')
    expect(phone.complete_verification!(code, token: result.token)).to be_invalid
  end

  it 'R5 invalidates verification when the subject changes' do
    phone.update!(verified_at: Time.current)
    phone.update!(e164: '+61400000002')
    expect(phone.reload).not_to be_verified
  end

  it 'R5 does not revive old challenges when the subject changes back' do
    result = phone.start_verification!
    code = phone.last_delivered_code
    phone.update!(e164: '+61400000002')
    phone.update!(e164: '+61400000001')
    expect(phone.complete_verification!(code, token: result.token)).to be_invalid
  end

  it 'R5 checks a stale object against the locked current subject' do
    result = phone.start_verification!
    code = phone.last_delivered_code
    PhoneVerification.find(phone.id).update!(e164: '+61400000002')
    expect(phone.complete_verification!(code, token: result.token)).to be_invalid
  end

  it 'R5 invalidates verified drafts when edited before saving' do
    draft = PhoneVerification.new(e164: '+61400000003')
    draft.start_verification!
    expect(draft.complete_verification!(draft.last_delivered_code)).to be_ok
    draft.e164 = '+61400000004'
    draft.save!
    expect(draft.reload).not_to be_verified
  end

  it 'R5 preserves a verified draft when it is saved without subject changes' do
    draft = PhoneVerification.new(e164: '+61400000003')
    draft.start_verification!
    draft.complete_verification!(draft.last_delivered_code)
    draft.save!
    expect(draft.reload).to be_verified
  end

  it 'R7 uses cryptographic randomness even if host code seeds Ruby random' do
    account = Account.new
    srand(123)
    first = account.send(:generate_recovery_plaintext)
    srand(123)
    expect(account.send(:generate_recovery_plaintext)).not_to eq(first)
  ensure
    srand
  end

  it 'R8 rechecks recovery lockout on a stale instance' do
    account = create(:account)
    code = account.generate_recovery_codes!.value.first
    Account.find(account.id).update!(recovery_locked_at: Time.current)
    expect(account.consume_recovery_code!(code)).to be_locked
  end

  it 'R21 applies model recovery limits' do
    account = create(:account)
    allow(Account).to receive(:auth_options).and_return(recoverable: {code_count: 2})
    expect(account.generate_recovery_codes!.value.size).to eq(2)
  end

  it 'R9 uses its own reset lookup without replacing Rails token methods' do
    account = create(:account)
    token = account.generate_password_reset_token!.value
    expect(Account.find_by_auth_password_reset_token(token)).to eq(account)
  end

  it 'R6 rejects a consumed reset token held by another instance' do
    account = create(:account)
    token = account.generate_password_reset_token!.value
    stale = Account.find(account.id)
    expect(account.reset_password_with_token!(token, password: 'replacement123')).to be_ok
    expect(stale.reset_password_with_token!(token, password: 'secondpassword123')).to be_invalid
  end
end
