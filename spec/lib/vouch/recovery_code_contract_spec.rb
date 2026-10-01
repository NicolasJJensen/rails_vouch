require "rails_helper"

RSpec.describe "Recovery code operations" do
  let(:account) { create(:account) }
  let(:credential) do
    account.two_factor_credentials.create!(verified_at: Time.current,
      two_factor_enabled_at: Time.current, otp_secret: ROTP::Base32.random)
  end

  %i[account credential].each do |kind|
    context "with a #{kind} owner" do
      let(:owner) { public_send(kind) }

      it "accepts equivalent formatting and rejects replay through the paired APIs" do
        code = owner.generate_recovery_codes!.value.first
        expect(code).to match(/\A[A-Z2-9]{4}-[A-Z2-9]{4}\z/)
        expect(owner.consume_recovery_code!(code.downcase.tr("-", " \n"))).to be_ok
        expect(owner.consume_recovery_code(code)).to be_invalid
        expect { owner.consume_recovery_code!(code) }.to raise_error(Vouch::OperationFailed) { |error|
          expect(error.result).to be_invalid
        }
      end

      it "counts each blank or incorrect direct attempt once" do
        owner.generate_recovery_codes!
        counter = kind == :account ? :recovery_attempts : :two_factor_failed_attempts
        [nil, "", "not-a-code"].each_with_index do |submitted, index|
          expect(owner.consume_recovery_code(submitted)).to be_invalid
          expect(owner.reload.public_send(counter)).to eq(index + 1)
        end
      end
    end
  end

  it "does not spend the last available attempt probing recovery before a valid TOTP" do
    credential.generate_recovery_codes!
    credential.update!(two_factor_failed_attempts: credential.send(:two_factorable_config).max_attempts - 1)
    result = credential.verify_challenge(ROTP::TOTP.new(credential.otp_secret).now, token: :totp)
    expect(result).to be_ok
    expect(credential.reload.two_factor_failed_attempts).to eq(0)
    expect(credential).not_to be_two_factor_locked
  end
end
