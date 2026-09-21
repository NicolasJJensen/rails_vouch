# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::Verifiable do
  let(:record) { PhoneVerification.create!(e164: "+15550001234") }

  describe "schema guard" do
    it "defers missing created_at errors until feature use" do
      klass = Class.new(ActiveRecord::Base) do
        self.table_name = "vouch_recovery_codes" # any table; we monkey-patch
      end
      allow(klass).to receive(:columns_hash).and_return({})
      klass.include(Vouch::Verifiable)
      expect { klass.allocate.start_verification! }.to raise_error(Vouch::SchemaError, /missing the created_at column/)
    end

    it "raises SchemaError when the challenge version column is missing" do
      klass = Class.new(ActiveRecord::Base) do
        self.table_name = "phone_verifications"
      end
      columns = Vouch::FeatureContracts.columns(:verifiable).to_h { |column| [column.to_s, double] }
      columns.delete("verification_version")
      allow(klass).to receive(:columns_hash).and_return(columns)

      klass.include(Vouch::Verifiable)
      expect { klass.allocate.start_verification! }
        .to raise_error(Vouch::SchemaError, /verification_version column/)
    end
  end

  describe "scopes" do
    it ".verified returns rows with a verified_at" do
      verified   = PhoneVerification.create!(e164: "+15550000001", verified_at: Time.current)
      unverified = PhoneVerification.create!(e164: "+15550000002")
      expect(PhoneVerification.verified).to    include(verified)
      expect(PhoneVerification.verified).not_to include(unverified)
    end

    it ".unverified returns rows where verified_at is nil" do
      verified   = PhoneVerification.create!(e164: "+15550000003", verified_at: Time.current)
      unverified = PhoneVerification.create!(e164: "+15550000004")
      expect(PhoneVerification.unverified).to    include(unverified)
      expect(PhoneVerification.unverified).not_to include(verified)
    end
  end

  describe "#verified?" do
    it "returns false when verified_at is nil" do
      expect(record.verified?).to be false
    end

    it "returns true once verified_at is set" do
      record.update!(verified_at: Time.current)
      expect(record.verified?).to be true
    end
  end

  describe "#verification_locked?" do
    it "returns false when verification_locked_at is nil" do
      expect(record.verification_locked?).to be false
    end

    it "returns true when locked within the duration window" do
      record.update!(verification_locked_at: 1.minute.ago)
      expect(record.verification_locked?).to be true
    end

    it "returns false after the lockout window elapses" do
      record.update!(verification_locked_at: 31.minutes.ago)
      expect(record.verification_locked?).to be false
    end
  end

  describe "#start_verification!" do
    it "returns an ok Result carrying a token" do
      result = record.start_verification!
      expect(result).to be_ok
      expect(result.token).to be_a(String)
    end

    it "calls deliver_verification_code with the issued code" do
      record.start_verification!
      expect(record.last_delivered_code).to be_a(String).and have_attributes(length: 6)
    end

    it "returns Result.locked without issuing when verification_locked?" do
      record.update!(verification_locked_at: 1.minute.ago)
      result = record.start_verification!
      expect(result).to be_locked
      expect(record.last_delivered_code).to be_nil
    end

    it "issues on a draft (unpersisted) record using the natural identifier" do
      draft  = PhoneVerification.new(e164: "+15550001111")
      result = draft.start_verification!

      expect(result).to be_ok
      expect(draft.challenge_token).to eq(result.token)
      expect(draft.last_delivered_code).to be_a(String)
    end

    it "sets challenge_token on self so it survives session serialization" do
      result = record.start_verification!
      expect(record.challenge_token).to eq(result.token)
    end

    it "lets delivery exceptions bubble (decisions 38, 40)" do
      allow(record).to receive(:deliver_verification_code).and_raise(StandardError, "transport down")
      expect { record.start_verification! }.to raise_error(StandardError, "transport down")
    end
  end

  describe "#complete_verification!" do
    it "returns true and sets verified_at on a correct code" do
      result = record.start_verification!
      code   = record.last_delivered_code

      expect(record.complete_verification!(code, token: result.token)).to be_ok
      expect(record.reload.verified_at).to be_present
      expect(record.verification_attempts).to eq(0)
    end

    it "returns false on a wrong code and increments the attempt counter" do
      result = record.start_verification!
      expect(record.complete_verification!("000000", token: result.token)).to be_invalid
      expect(record.reload.verification_attempts).to eq(1)
      expect(record.verified_at).to be_nil
    end

    it "propagates verifier errors without recording a failed attempt" do
      result = record.start_verification!
      allow(OtpCourier::OTP).to receive(:consume).and_raise(OtpCourier::Error, "verifier unavailable")

      expect { record.complete_verification!("123456", token: result.token) }
        .to raise_error(OtpCourier::Error, "verifier unavailable")

      expect(record.reload).to have_attributes(verification_attempts: 0, verification_locked_at: nil)
    end

    it "returns false on a blank code without raising" do
      result = record.start_verification!
      expect(record.complete_verification!("", token: result.token)).to be_invalid
      expect(record.complete_verification!(nil, token: result.token)).to be_invalid
    end

    it "strips surrounding whitespace from the submitted code (decision 51)" do
      result = record.start_verification!
      code   = record.last_delivered_code
      expect(record.complete_verification!("  #{code}  ", token: result.token)).to be_ok
    end

    it "returns false when verification_locked?" do
      result = record.start_verification!
      code   = record.last_delivered_code
      record.update!(verification_locked_at: 1.minute.ago)
      expect(record.complete_verification!(code, token: result.token)).to be_locked
    end

    it "locks the credential after max_attempts wrong codes" do
      max = Vouch.configuration.verifiable.max_attempts
      result = record.start_verification!
      max.times { record.complete_verification!("000000", token: result.token) }
      expect(record.reload.verification_locked_at).to be_present
    end

    it "returns cancelled without retaining a threshold attempt when the host cancels the lock write" do
      config = Vouch.configuration.verifiable
      previous_max_attempts = config.max_attempts
      callback = :cancel_verification_lockout
      config.max_attempts = 1
      PhoneVerification.define_method(callback) do
        raise ActiveRecord::Rollback if will_save_change_to_verification_locked_at?
      end
      PhoneVerification.set_callback(:update, :before, callback)

      result = record.start_verification!

      expect(record.complete_verification!("000000", token: result.token)).to be_cancelled
      expect(record.reload).to have_attributes(verification_attempts: 0, verification_locked_at: nil)
    ensure
      config.max_attempts = previous_max_attempts if config
      PhoneVerification.skip_callback(:update, :before, callback) if callback
      PhoneVerification.remove_method(callback) if callback && PhoneVerification.method_defined?(callback)
    end

    it "returns false when the token payload's subject does not match the record" do
      other  = PhoneVerification.create!(e164: "+15550002222")
      result = other.start_verification!
      # Submit other's token to `record`. Even with a valid OTP, subject mismatch fails.
      expect(record.complete_verification!(other.last_delivered_code, token: result.token)).to be_invalid
    end

    it "binds challenges to subject changes made through attribute APIs" do
      result = record.start_verification!
      code = record.last_delivered_code
      record[:e164] = "+15550007771"
      record.assign_attributes(e164: "+15550007772")
      record.save!

      expect(record.complete_verification!(code, token: result.token)).to be_invalid
      expect(record.reload).not_to be_verified
    end

    it "invalidates challenges when an aliased subject is assigned" do
      klass = Class.new(PhoneVerification) do
        alias_attribute :contact_number, :e164
      end
      stub_const("AliasedPhoneVerification", klass)
      row = klass.create!(e164: "+15550007773")
      result = row.start_verification!
      code = row.last_delivered_code
      row[:contact_number] = "+15550007774"
      row.save!

      expect(row.complete_verification!(code, token: result.token)).to be_invalid
    end

    it "invalidates verification when the configured subject is an alias" do
      klass = Class.new(PhoneVerification) do
        alias_attribute :number, :e164
        self.verifiable_subject_attribute = :number
      end
      stub_const("AliasConfiguredPhoneVerification", klass)
      row = klass.create!(number: "+15550007775", verified_at: Time.current)
      original_version = row.verification_version

      row.number = "+15550007776"
      row.save!

      expect(row.reload).not_to be_verified
      expect(row.verification_version).to be > original_version
    end

    it "verifies a draft in memory without saving" do
      draft = PhoneVerification.new(e164: "+15550004444")
      draft.start_verification!
      code = draft.last_delivered_code

      expect(draft.complete_verification!(code)).to be_ok
      expect(draft.verified_at).to be_present
      expect(draft).not_to be_persisted
    end

    it "reads the token from challenge_token when no token: kwarg is passed" do
      record.start_verification!
      code = record.last_delivered_code
      # challenge_token is on the model; no explicit token: needed.
      expect(record.complete_verification!(code)).to be_ok
    end
  end

  describe "duplicate credential subjects" do
    it "allows persisted pending credentials with the same natural subject" do
      subject = "+15550009999"
      PhoneVerification.create!(e164: subject)

      duplicate = PhoneVerification.new(e164: subject)
      expect(duplicate).to be_valid
      expect { duplicate.save! }.to change(PhoneVerification, :count).by(1)
    end

    it "keeps proofs bound to their issuing record when subjects match" do
      subject = "+15550008888"
      issuing_record = PhoneVerification.create!(e164: subject)
      other_record = PhoneVerification.create!(e164: subject)
      issued = issuing_record.start_verification!

      expect(other_record.complete_verification!(issuing_record.last_delivered_code, token: issued.token)).to be_invalid
      expect(issuing_record.complete_verification!(issuing_record.last_delivered_code, token: issued.token)).to be_ok
      expect(issuing_record.reload).to be_verified
      expect(other_record.reload).not_to be_verified
    end
  end

  describe "#unverify!" do
    it "clears verified_at" do
      record.update!(verified_at: Time.current)
      record.unverify!
      expect(record.reload.verified_at).to be_nil
    end
  end

  describe "#deliver_verification_code" do
    it "fails fast when a model does not override it" do
      bare = Class.new(ActiveRecord::Base) do
        self.table_name = "phone_verifications"
        include Vouch::Verifiable
      end
      stub_const("BarePhone", bare)

      bare_record = BarePhone.create!(e164: "+15550003333")
      expect { bare_record.start_verification! }
        .to raise_error(Vouch::ConfigurationError, /deliver_verification_code/)
    end
  end
end
