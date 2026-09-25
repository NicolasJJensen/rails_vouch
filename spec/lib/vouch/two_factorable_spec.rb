# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::TwoFactorable do
  let(:account) { create(:account) }
  let(:credential) do
    # Non-TOTP credential so we exercise the courier flow rather than the
    # dummy's TOTP override. Specs for the TOTP fork live alongside the
    # request specs.
    TwoFactorCredential.create!(account: account, type: "email")
  end

  describe "schema guard" do
    it "defers missing created_at errors until feature use" do
      klass = Class.new(ActiveRecord::Base) do
        self.table_name = "vouch_recovery_codes"
      end
      allow(klass).to receive(:columns_hash).and_return({})
      klass.include(Vouch::TwoFactorable)
      expect { klass.allocate.challenge! }.to raise_error(Vouch::SchemaError, /missing the created_at column/)
    end
  end

  describe ".enabled scope" do
    it "returns credentials with two_factor_enabled_at set" do
      enabled  = TwoFactorCredential.create!(account: account, type: "email",
                                             verified_at: Time.current,
                                             two_factor_enabled_at: Time.current)
      disabled = TwoFactorCredential.create!(account: account, type: "email",
                                             verified_at: Time.current)
      expect(TwoFactorCredential.enabled).to     include(enabled)
      expect(TwoFactorCredential.enabled).not_to include(disabled)
    end
  end

  describe "#two_factor_label" do
    it "reads from the model's declared two_factor_label_attribute" do
      klass = Class.new(TwoFactorCredential) do
        self.two_factor_label_attribute = :phone_number
      end
      row = klass.new(phone_number: "+15550009999")
      expect(row.two_factor_label).to eq("+15550009999")
    end

    it "falls back to verifiable_subject_attribute when no label attr is set" do
      klass = Class.new(TwoFactorCredential) do
        self.verifiable_subject_attribute = :phone_number
        self.two_factor_label_attribute = nil
      end
      row = klass.new(phone_number: "+15550008888")
      expect(row.two_factor_label).to eq("+15550008888")
    end

    it "raises when neither attribute is declared" do
      klass = Class.new(TwoFactorCredential) do
        self.two_factor_label_attribute = nil
        self.verifiable_subject_attribute = nil
      end
      expect { klass.new.two_factor_label }
        .to raise_error(NotImplementedError, /display attribute/)
    end
  end

  describe ".two_factor_auth_name" do
    it "defaults to the model's singular name" do
      stub_const("DefaultNamedCredential", Class.new(ActiveRecord::Base) do
        self.table_name = "two_factor_credentials"
        include Vouch::TwoFactorable
      end)

      expect(DefaultNamedCredential.two_factor_auth_name).to eq(:default_named_credential)
      expect(DefaultNamedCredential.allocate.authentication_method).to eq(:default_named_credential)
    end

    it "declares an inherited name without changing the parent when a child overrides it" do
      stub_const("NamedCredential", Class.new(ActiveRecord::Base) do
        self.table_name = "two_factor_credentials"
        include Vouch::TwoFactorable
      end)
      stub_const("ChildNamedCredential", Class.new(NamedCredential))

      NamedCredential.two_factor_auth_name :sms

      expect(NamedCredential.two_factor_auth_name).to eq(:sms)
      expect(ChildNamedCredential.two_factor_auth_name).to eq(:sms)

      ChildNamedCredential.two_factor_auth_name :totp

      expect(NamedCredential.two_factor_auth_name).to eq(:sms)
      expect(ChildNamedCredential.two_factor_auth_name).to eq(:totp)
    end

    it "allows a credential to override authentication_method per record" do
      stub_const("MultiMethodCredential", Class.new(TwoFactorCredential) do
        def authentication_method
          :hardware_key
        end
      end)

      expect(MultiMethodCredential.allocate.authentication_method).to eq(:hardware_key)
    end
  end

  describe "#two_factor_enabled?" do
    it "returns false when two_factor_enabled_at is nil" do
      expect(credential.two_factor_enabled?).to be false
    end

    it "returns true when two_factor_enabled_at is set" do
      credential.update!(two_factor_enabled_at: Time.current)
      expect(credential.two_factor_enabled?).to be true
    end
  end

  describe "per-account configuration" do
    it "raises when distinct MFA-enabled owner records are ambiguous" do
      owner = create(:account)
      creator = create(:account)
      reflection = ->(name) { double(polymorphic?: false, name: name, klass: Account) }
      allow(credential.class).to receive(:reflect_on_all_associations).with(:belongs_to)
        .and_return([reflection.call(:account), reflection.call(:creator)])
      credential.define_singleton_method(:account) { owner }
      credential.define_singleton_method(:creator) { creator }

      expect { credential.send(:two_factor_account) }
        .to raise_error(Vouch::ConfigurationError, /multiple distinct/)
    end

    it "deduplicates aliases that point to the same MFA-enabled owner" do
      owner = create(:account)
      reflection = ->(name) { double(polymorphic?: false, name: name, klass: Account) }
      allow(credential.class).to receive(:reflect_on_all_associations).with(:belongs_to)
        .and_return([reflection.call(:account), reflection.call(:creator)])
      credential.define_singleton_method(:account) { owner }
      credential.define_singleton_method(:creator) { owner }

      expect(credential.send(:two_factor_account)).to eq(owner)
    end

    it "allows an explicit instance owner override for ambiguous associations" do
      owner = create(:account)
      creator = create(:account)
      reflection = ->(name) { double(polymorphic?: false, name: name, klass: Account) }
      allow(credential.class).to receive(:reflect_on_all_associations).with(:belongs_to)
        .and_return([reflection.call(:account), reflection.call(:creator)])
      credential.define_singleton_method(:account) { owner }
      credential.define_singleton_method(:creator) { creator }
      credential.define_singleton_method(:two_factor_account) { creator }

      expect(credential.send(:two_factor_account)).to eq(creator)
    end

    it "resolves a non-polymorphic owner class without loading its record" do
      allow(credential).to receive(:account).and_raise("owner record must not be loaded")

      expect(credential.send(:two_factor_account_class)).to eq(Account)
    end

    it "raises an actionable error when owner associations are ambiguous" do
      stub_const("OtherTwoFactorAccount", Class.new(Account))
      stub_const("AmbiguousTwoFactorCredential", Class.new(TwoFactorCredential) do
        belongs_to :billing_account, class_name: "OtherTwoFactorAccount", optional: true
      end)
      ambiguous = AmbiguousTwoFactorCredential.new

      expect { ambiguous.send(:two_factor_account_class) }
        .to raise_error(Vouch::ConfigurationError, /two_factor_account_class|ambiguous/i)
    end

    it "uses the loaded object class for a polymorphic owner" do
      stub_const("PolymorphicTwoFactorAccount", Class.new(Account))
      PolymorphicTwoFactorAccount.authenticates_with :two_factorable,
        two_factorable: {max_attempts: 2}
      reflection = double(polymorphic?: true, name: :owner, foreign_type: :owner_type)
      association = double(loaded?: true, target: PolymorphicTwoFactorAccount.new)
      allow(credential.class).to receive(:reflect_on_all_associations).with(:belongs_to).and_return([reflection])
      credential.define_singleton_method(:owner) { association.target }
      allow(credential).to receive(:association).with(:owner).and_return(association)
      allow(credential).to receive(:[]).with(:owner_type).and_return(nil)

      expect(credential.send(:two_factor_account_class)).to eq(PolymorphicTwoFactorAccount)
    end

    it "uses the owning account class settings for all challenge attributes" do
      stub_const("ConfiguredTwoFactorAccount", Class.new(Account) do
        authenticates_with :two_factorable,
          two_factorable: {
            max_attempts: 2,
            challenge_validity: 17.minutes,
            lockout_duration: 9.minutes,
            length: 8
          }
      end)
      reflection = double(polymorphic?: false, klass: ConfiguredTwoFactorAccount)
      allow(credential.class).to receive(:reflect_on_all_associations).with(:belongs_to).and_return([reflection])
      allow(credential).to receive(:account).and_return(ConfiguredTwoFactorAccount.new)

      config = credential.send(:two_factorable_config)
      expect(config.max_attempts).to eq(2)
      expect(config.challenge_validity).to eq(17.minutes)
      expect(config.lockout_duration).to eq(9.minutes)
      expect(config.length).to eq(8)
    end

    it "uses the per-account challenge validity and length at runtime" do
      stub_const("RuntimeTwoFactorAccount", Class.new(Account) do
        authenticates_with :two_factorable,
          two_factorable: {challenge_validity: 17.minutes, length: 8}
      end)
      reflection = double(polymorphic?: false, klass: RuntimeTwoFactorAccount)
      allow(credential.class).to receive(:reflect_on_all_associations).with(:belongs_to).and_return([reflection])
      allow(credential).to receive(:account).and_return(RuntimeTwoFactorAccount.new)
      credential.update!(verified_at: Time.current, two_factor_enabled_at: Time.current)
      allow(credential).to receive(:deliver_two_factor_code)
      expect(OtpCourier::OTP).to receive(:issue).with(
        hash_including(validity: 17.minutes, length: 8)
      ).and_call_original

      credential.challenge!
    end
  end

  describe "#two_factor_locked?" do
    it "returns false when two_factor_locked_at is nil" do
      expect(credential.two_factor_locked?).to be false
    end

    it "returns true inside the lockout window" do
      credential.update!(two_factor_locked_at: 1.minute.ago)
      expect(credential.two_factor_locked?).to be true
    end

    it "returns false after the lockout window elapses" do
      credential.update!(two_factor_locked_at: 31.minutes.ago)
      expect(credential.two_factor_locked?).to be false
    end
  end

  describe "#enable_two_factor!" do
    it "sets two_factor_enabled_at when the credential is verified" do
      credential.update!(verified_at: Time.current)
      credential.enable_two_factor!
      expect(credential.reload.two_factor_enabled_at).to be_present
    end

    it "raises UnverifiedCredential when the credential is not verified" do
      expect { credential.enable_two_factor! }
        .to raise_error(Vouch::UnverifiedCredential, /not verified/)
    end

    it "rechecks verification while holding the row lock when another instance changed the subject" do
      credential.update!(otp_secret: "old-secret")
      credential.update!(verified_at: Time.current)
      stale = TwoFactorCredential.find(credential.id)
      changed = TwoFactorCredential.find(credential.id)

      changed.update!(otp_secret: "new-secret")

      expect { stale.enable_two_factor! }
        .to raise_error(Vouch::UnverifiedCredential, /not verified/)
      expect(credential.reload.two_factor_enabled_at).to be_nil
    end
  end

  describe "#disable_two_factor!" do
    it "clears two_factor_enabled_at" do
      credential.update!(verified_at: Time.current, two_factor_enabled_at: Time.current)
      credential.disable_two_factor!
      expect(credential.reload.two_factor_enabled_at).to be_nil
    end

    it "leaves verified_at intact" do
      verified_at = Time.current
      credential.update!(verified_at: verified_at, two_factor_enabled_at: Time.current)
      credential.disable_two_factor!
      expect(credential.reload.verified_at).to be_within(1.second).of(verified_at)
    end
  end

  describe "#challenge!" do
    # Override the dummy's TOTP fork so we exercise the courier flow.
    before do
      credential.update!(otp_secret: nil)
      credential.update!(verified_at: Time.current, two_factor_enabled_at: Time.current)
      allow(credential).to receive(:deliver_two_factor_code)
    end

    it "returns an ok Result carrying a token" do
      result = credential.challenge!
      expect(result).to be_ok
      expect(result.token).to be_a(String)
    end

    it "calls deliver_two_factor_code with the issued code" do
      expect(credential).to receive(:deliver_two_factor_code).with(a_string_matching(/\A\d{6}\z/))
      credential.challenge!
    end

    it "returns Result.locked without issuing when two_factor_locked?" do
      credential.update!(two_factor_locked_at: 1.minute.ago)
      expect(credential).not_to receive(:deliver_two_factor_code)
      expect(credential.challenge!).to be_locked
    end

    it "raises ArgumentError on an unpersisted record" do
      bare = TwoFactorCredential.new(account: account)
      expect { bare.challenge! }.to raise_error(ArgumentError, /unpersisted/)
    end

    it "bubbles delivery configuration errors" do
      allow(credential).to receive(:deliver_two_factor_code).and_raise(
        Vouch::ConfigurationError,
        "deliver_two_factor_code is unavailable"
      )
      expect { credential.challenge! }
        .to raise_error(Vouch::ConfigurationError, /deliver_two_factor_code/)
    end
  end

  describe "#verify_challenge" do
    let(:issued)  { credential.challenge! }
    let(:code) do
      # Capture the delivered code via the deliver hook.
      delivered = nil
      allow(credential).to receive(:deliver_two_factor_code) { |c| delivered = c }
      credential.update!(otp_secret: nil) # ensure courier flow
      _ = credential.challenge!
      delivered
    end

    before do
      credential.update!(otp_secret: nil)
      credential.update!(verified_at: Time.current, two_factor_enabled_at: Time.current)
    end

    it "rejects verification for a disabled credential" do
      captured = nil
      allow(credential).to receive(:deliver_two_factor_code) { |c| captured = c }
      credential.update!(verified_at: Time.current, two_factor_enabled_at: nil)
      result = credential.challenge! # disabled credentials cannot issue a challenge

      expect(result).to be_locked
      expect(credential.verify_challenge(captured, token: result.token)).to be_locked
    end

    it "rejects a challenge issued before the credential was disabled" do
      captured = nil
      allow(credential).to receive(:deliver_two_factor_code) { |c| captured = c }
      result = credential.challenge!
      credential.disable_two_factor!

      expect(credential.verify_challenge(captured, token: result.token)).to be_locked
    end

    it "invalidates verification when an authenticator secret changes" do
      credential.update!(otp_secret: SecureRandom.hex(20))
      credential.update!(verified_at: Time.current)
      code = nil
      allow(credential).to receive(:deliver_verification_code) { |value| code = value }
      result = credential.start_verification!
      credential.update!(otp_secret: SecureRandom.hex(20))

      expect(credential.complete_verification!(code, token: result.token)).to be_invalid
      expect(credential.reload).not_to be_verified
    end

    it "rejects verification for an unverified credential" do
      captured = nil
      allow(credential).to receive(:deliver_two_factor_code) { |c| captured = c }
      credential.update!(verified_at: nil, two_factor_enabled_at: Time.current)
      result = credential.challenge! # the dummy model enforces the same policy

      expect(result).to be_locked
      expect(credential.verify_challenge(captured, token: result.token)).to be_locked
    end

    it "returns true on a correct code, resets the counter, and stamps last_used_at" do
      captured = nil
      allow(credential).to receive(:deliver_two_factor_code) { |c| captured = c }
      result = credential.challenge!

      expect(credential.verify_challenge(captured, token: result.token)).to be_ok
      credential.reload
      expect(credential.two_factor_failed_attempts).to eq(0)
      expect(credential.two_factor_last_used_at).to be_present
    end

    it "returns false and increments the counter on a wrong code" do
      allow(credential).to receive(:deliver_two_factor_code)
      result = credential.challenge!
      expect(credential.verify_challenge("000000", token: result.token)).to be_invalid
      expect(credential.reload.two_factor_failed_attempts).to eq(1)
    end

    it "propagates verifier errors without recording a failed attempt" do
      allow(credential).to receive(:deliver_two_factor_code)
      result = credential.challenge!
      allow(OtpCourier::OTP).to receive(:consume).and_raise(OtpCourier::Error, "verifier unavailable")

      expect { credential.verify_challenge("123456", token: result.token) }
        .to raise_error(OtpCourier::Error, "verifier unavailable")

      expect(credential.reload).to have_attributes(two_factor_failed_attempts: 0, two_factor_locked_at: nil)
    end

    it "returns false on blank input without raising" do
      allow(credential).to receive(:deliver_two_factor_code)
      result = credential.challenge!
      expect(credential.verify_challenge("",  token: result.token)).to be_invalid
      expect(credential.verify_challenge(nil, token: result.token)).to be_invalid
    end

    it "strips surrounding whitespace from the submitted code (decision 51)" do
      captured = nil
      allow(credential).to receive(:deliver_two_factor_code) { |c| captured = c }
      result = credential.challenge!
      expect(credential.verify_challenge("  #{captured}  ", token: result.token)).to be_ok
    end

    it "returns false when two_factor_locked?" do
      allow(credential).to receive(:deliver_two_factor_code)
      result = credential.challenge!
      credential.update!(two_factor_locked_at: 1.minute.ago)
      expect(credential.verify_challenge("000000", token: result.token)).to be_locked
    end

    it "locks the credential after max_attempts wrong codes" do
      max = Vouch.configuration.two_factorable.max_attempts
      allow(credential).to receive(:deliver_two_factor_code)
      result = credential.challenge!
      max.times { credential.verify_challenge("000000", token: result.token) }
      expect(credential.reload.two_factor_locked_at).to be_present
    end

    it "returns cancelled without retaining a threshold attempt when the host cancels the lock write" do
      config = Vouch.configuration.two_factorable
      previous_max_attempts = config.max_attempts
      callback = :cancel_two_factor_lockout
      config.max_attempts = 1
      TwoFactorCredential.define_method(callback) do
        raise ActiveRecord::Rollback if will_save_change_to_two_factor_locked_at?
      end
      TwoFactorCredential.set_callback(:update, :before, callback)

      allow(credential).to receive(:deliver_two_factor_code)
      result = credential.challenge!

      expect(credential.verify_challenge("000000", token: result.token)).to be_cancelled
      expect(credential.reload).to have_attributes(two_factor_failed_attempts: 0, two_factor_locked_at: nil)
    ensure
      config.max_attempts = previous_max_attempts if config
      TwoFactorCredential.skip_callback(:update, :before, callback) if callback
      TwoFactorCredential.remove_method(callback) if callback && TwoFactorCredential.method_defined?(callback)
    end

    it "returns false when the token payload's id does not match the record" do
      other = TwoFactorCredential.create!(account: account, type: "email")
      other_code = nil
      allow(other).to receive(:deliver_two_factor_code) { |c| other_code = c }
      other_result = other.challenge!
      expect(credential.verify_challenge(other_code, token: other_result.token)).to be_invalid
    end
  end

  describe "#record_two_factor_use!" do
    it "bumps two_factor_last_used_at" do
      expect { credential.record_two_factor_use! }
        .to change { credential.reload.two_factor_last_used_at }.from(nil)
    end

    it "does NOT clear the failed-attempt counter" do
      credential.update!(two_factor_failed_attempts: 3)
      credential.record_two_factor_use!
      expect(credential.reload.two_factor_failed_attempts).to eq(3)
    end
  end
end
