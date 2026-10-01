require "rails_helper"

RSpec.describe Vouch::RecoveryCodeAssociation do
  [false, true].each do |credential_owned|
    [false, true].each do |polymorphic|
      context "#{credential_owned ? 'credential' : 'account'} recovery with #{polymorphic ? 'polymorphic' : 'concrete'} storage" do
        before do
          ActiveRecord::Base.connection.create_table(:selected_recovery_codes, force: true) do |table|
            table.references :owner, polymorphic: polymorphic, null: false
            table.string :code_digest, null: false
            table.datetime :used_at
          end
          stub_const("SelectedRecoveryCode", Class.new(ApplicationRecord) do
            self.table_name = "selected_recovery_codes"
          end)
          owner_class = Class.new(credential_owned ? TwoFactorCredential : Account)
          stub_const("SelectedRecoveryOwner", owner_class)
          options = { class_name: "SelectedRecoveryCode", dependent: :destroy }
          options.merge!(polymorphic ? { as: :owner } : { foreign_key: :owner_id })
          owner_class.has_many :selected_codes, **options
          owner_class.recovery_codes_from :selected_codes
        end

        after do
          ActiveRecord::Base.connection.drop_table(:selected_recovery_codes)
        end

        it "replaces and consumes only the configured owner's set" do
          first, second = 2.times.map do
            if credential_owned
              SelectedRecoveryOwner.create!(account: create(:account), verified_at: Time.current,
                two_factor_enabled_at: Time.current)
            else
              SelectedRecoveryOwner.create!(email_address: "#{SecureRandom.hex(8)}@example.com", password: "password123")
            end
          end
          old = first.generate_recovery_codes!.value.first
          other = second.generate_recovery_codes!.value.first
          current = first.generate_recovery_codes!.value.first
          expect(first.consume_recovery_code(old)).to be_invalid
          expect(first.consume_recovery_code(other)).to be_invalid
          expect(first.consume_recovery_code(current)).to be_ok
          expect(first.consume_recovery_code(current)).to be_invalid
          expect(second.consume_recovery_code(other)).to be_ok
          expect(SelectedRecoveryCode.count).to eq(20)
        end
      end
    end
  end

  it "reports a missing relation as a configuration error" do
    stub_const("MissingRecoveryOwner", Class.new(Account) do
      recovery_codes_from :missing_codes
    end)
    expect { MissingRecoveryOwner.new.recovery_codes_remaining }
      .to raise_error(Vouch::ConfigurationError, /direct has_many/)
  end
end
