require 'rails_helper'

RSpec.describe 'Authentication persistence failures' do
  def cancelling(model, event, timing)
    callback = proc { raise ActiveRecord::Rollback }
    model.set_callback(event, timing, callback)
    yield
  ensure
    model.skip_callback(event, timing, callback)
  end

  %i[before after].each do |timing|
    context "when a host #{timing} callback cancels persistence" do
      it 'does not consume or verify an OTP' do
        phone = create(:phone_verification)
        issued = phone.start_verification!
        code = phone.last_delivered_code
        nonce = phone.verification_nonce
        cancelling(PhoneVerification, :update, timing) do
          2.times do
            expect(phone.reload.complete_verification!(code, token: issued.token)).to be_cancelled
            expect(phone.reload.verified?).to be false
            expect(phone.verification_nonce).to eq(nonce)
          end
        end
        expect(phone.complete_verification!(code, token: issued.token)).to be_ok
      end

      it 'does not consume a magic-link proof' do
        phone = create(:phone_verification)
        issued = phone.issue_sign_in_code!
        code = phone.last_delivered_sign_in_code
        nonce = phone.sign_in_nonce
        cancelling(PhoneVerification, :update, timing) do
          expect(phone.verify_sign_in_code(code, token: issued.token)).to be_cancelled
          expect(phone.reload.sign_in_nonce).to eq(nonce)
        end
        expect(phone.verify_sign_in_code(code, token: issued.token)).to be_ok
      end

      it 'does not consume a second-factor proof' do
        credential = create(:account).two_factor_credentials.create!(verified_at: Time.current, two_factor_enabled_at: Time.current)
        code = nil
        credential.define_singleton_method(:deliver_two_factor_code) { |value| code = value }
        issued = credential.challenge!
        nonce = credential.two_factor_nonce
        cancelling(TwoFactorCredential, :update, timing) do
          expect(credential.verify_challenge(code, token: issued.token)).to be_cancelled
          expect(credential.reload.two_factor_nonce).to eq(nonce)
          expect(credential.two_factor_last_used_at).to be_nil
        end
        expect(credential.verify_challenge(code, token: issued.token)).to be_ok
      end

      it 'does not consume a signed verification link' do
        link = create(:invitation_link)
        token = link.confirmation_token
        nonce = link.confirmation_nonce
        cancelling(InvitationLink, :update, timing) do
          expect(InvitationLink.consume_token(token)).to be_invalid
          expect(link.reload.verified?).to be false
          expect(link.confirmation_nonce).to eq(nonce)
        end
        result = InvitationLink.consume_token(token)
        expect(result).to be_ok
        expect(result.value).to eq(link)
      end

      it 'does not consume a backup code' do
        credential = create(:account).two_factor_credentials.create!(
          verified_at: Time.current, two_factor_enabled_at: Time.current
        )
        row = credential.backup_codes.create!(code_digest: BCrypt::Password.create('backup-proof'))
        cancelling(BackupCode, :update, timing) do
          2.times do
            expect(credential.consume_backup_code!('backup-proof')).to be_cancelled
            expect(row.reload.used_at).to be_nil
          end
        end
        expect(credential.consume_backup_code!('backup-proof')).to be_ok
      end

      it 'does not reset a password or clear its token' do
        account = create(:account)
        token = account.generate_password_reset_token!.value
        digest = account.password_digest
        cancelling(Account, :update, timing) do
          expect(account.reset_password_with_token!(token, password: 'replacement-password')).to be_cancelled
          expect(account.reload.password_digest).to eq(digest)
          expect(Account.find_by_auth_password_reset_token(token)).to eq(account)
        end
        expect(account.reset_password_with_token!(token, password: 'replacement-password')).to be_ok
      end

      it 'does not deliver an OTP whose nonce was not saved' do
        phone = create(:phone_verification)
        cancelling(PhoneVerification, :update, timing) do
          expect { phone.start_verification! }.to raise_error(ActiveRecord::RecordNotSaved)
          expect(phone.last_delivered_code).to be_nil
          expect(phone.reload.verification_nonce).to be_nil
        end
      end

      it 'does not return a password reset token whose digest was not saved' do
        account = create(:account)
        cancelling(Account, :update, timing) do
          expect { account.generate_password_reset_token! }.to raise_error(ActiveRecord::RecordNotSaved)
          expect(account.reload.password_reset_token_digest).to be_nil
        end
      end

      it 'does not return backup codes when a child creation is cancelled' do
        credential = create(:account).two_factor_credentials.create!
        old = credential.backup_codes.create!(code_digest: BCrypt::Password.create('old-backup'))
        cancelling(BackupCode, :create, timing) do
          expect { credential.regenerate_backup_codes!(count: 2) }.to raise_error(ActiveRecord::RecordNotSaved)
          expect(credential.backup_codes.reload.ids).to eq([old.id])
        end
      end

      it 'does not return recovery codes when a child creation is cancelled' do
        account = create(:account)
        old = account.vouch_recovery_codes.create!(code_digest: BCrypt::Password.create('OLDRECOVERY'))
        allow(account).to receive(:recoverable_value).and_call_original
        allow(account).to receive(:recoverable_value).with(:code_count).and_return(2)
        cancelling(Vouch::RecoveryCode, :create, timing) do
          expect { account.generate_recovery_codes! }.to raise_error(ActiveRecord::RecordNotSaved)
          expect(account.vouch_recovery_codes.reload.ids).to eq([old.id])
        end
      end

      [Account, Vouch::RecoveryCode].each do |model|
        it "restores a recovery code if #{model.name} cancels consumption" do
          account = create(:account, recovery_attempts: 2)
          row = account.vouch_recovery_codes.create!(code_digest: BCrypt::Password.create('RECOVERY'))
          cancelling(model, :update, timing) do
          expect(account.consume_recovery_code!('RECOVERY')).to be_cancelled
            expect(row.reload.used_at).to be_nil
            expect(account.reload.recovery_attempts).to eq(2)
          end
        expect(account.consume_recovery_code!('RECOVERY')).to be_ok
        end
      end
    end
  end

  it 'propagates unexpected database errors during consumption' do
    credential = create(:account).two_factor_credentials.create!(
      verified_at: Time.current, two_factor_enabled_at: Time.current
    )
    credential.backup_codes.create!(code_digest: BCrypt::Password.create('backup-proof'))
    allow_any_instance_of(BackupCode).to receive(:update!).and_raise(ActiveRecord::StatementInvalid, 'database error')
    expect { credential.consume_backup_code!('backup-proof') }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it 'preserves the explicit exception from an aborting callback' do
    credential = create(:account).two_factor_credentials.create!
    row = credential.backup_codes.create!(code_digest: BCrypt::Password.create('old-backup'))
    callback = proc { throw :abort }
    BackupCode.set_callback(:destroy, :before, callback)
    expect { credential.regenerate_backup_codes!(count: 1) }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(credential.backup_codes.reload.ids).to eq([row.id])
  ensure
    BackupCode.skip_callback(:destroy, :before, callback) if callback
  end
end
