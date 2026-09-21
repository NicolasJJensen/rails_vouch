# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::MagicLinkable do
  let(:record) { PhoneVerification.create!(e164: "+15550001234") }

  describe "schema guard" do
    it "defers missing created_at errors until feature use" do
      klass = Class.new(ActiveRecord::Base) do
        self.table_name = "vouch_recovery_codes"
      end
      allow(klass).to receive(:columns_hash).and_return({})
      klass.include(Vouch::MagicLinkable)
      expect { klass.allocate.issue_sign_in_code! }.to raise_error(Vouch::SchemaError, /missing the created_at column/)
    end
  end

  describe "#sign_in_locked?" do
    it "returns false when sign_in_locked_at is nil" do
      expect(record.sign_in_locked?).to be false
    end

    it "returns true when locked within the duration window" do
      record.update!(sign_in_locked_at: 1.minute.ago)
      expect(record.sign_in_locked?).to be true
    end

    it "returns false after the lockout window elapses" do
      record.update!(sign_in_locked_at: 31.minutes.ago)
      expect(record.sign_in_locked?).to be false
    end
  end

  describe "#issue_sign_in_code!" do
    it "returns an ok Result carrying a token" do
      result = record.issue_sign_in_code!
      expect(result).to be_ok
      expect(result.token).to be_a(String)
    end

    it "calls deliver_sign_in_code with the issued code" do
      record.issue_sign_in_code!
      expect(record.last_delivered_sign_in_code).to be_a(String).and have_attributes(length: 6)
    end

    it "returns Result.locked without issuing when sign_in_locked?" do
      record.update!(sign_in_locked_at: 1.minute.ago)
      result = record.issue_sign_in_code!
      expect(result).to be_locked
      expect(record.last_delivered_sign_in_code).to be_nil
    end

    it "raises ArgumentError on an unpersisted record" do
      expect { PhoneVerification.new(e164: "+15550001111").issue_sign_in_code! }
        .to raise_error(ArgumentError, /unpersisted/)
    end

    it "fails fast when the host has no delivery implementation" do
      default_delivery = Vouch::MagicLinkable.instance_method(:deliver_sign_in_code)
      allow(record).to receive(:deliver_sign_in_code) do |code|
        default_delivery.bind(record).call(code)
      end

      expect { record.issue_sign_in_code! }
        .to raise_error(Vouch::ConfigurationError, /deliver_sign_in_code/)
    end

    it "lets delivery exceptions bubble" do
      allow(record).to receive(:deliver_sign_in_code).and_raise(StandardError, "transport down")
      expect { record.issue_sign_in_code! }.to raise_error(StandardError, "transport down")
    end
  end

  describe "#verify_sign_in_code" do
    it "returns true on a correct code and clears the attempt counter" do
      result = record.issue_sign_in_code!
      code   = record.last_delivered_sign_in_code

      expect(record.verify_sign_in_code(code, token: result.token)).to be_ok
      expect(record.reload.sign_in_attempts).to eq(0)
    end

    it "returns false on a wrong code and increments the attempt counter" do
      result = record.issue_sign_in_code!
      expect(record.verify_sign_in_code("000000", token: result.token)).to be_invalid
      expect(record.reload.sign_in_attempts).to eq(1)
    end

    it "propagates verifier errors without recording a failed attempt" do
      result = record.issue_sign_in_code!
      allow(OtpCourier::OTP).to receive(:consume).and_raise(OtpCourier::Error, "verifier unavailable")

      expect { record.verify_sign_in_code("123456", token: result.token) }
        .to raise_error(OtpCourier::Error, "verifier unavailable")

      expect(record.reload).to have_attributes(sign_in_attempts: 0, sign_in_locked_at: nil)
    end

    it "returns false on blank input without raising" do
      result = record.issue_sign_in_code!
      expect(record.verify_sign_in_code("",  token: result.token)).to be_invalid
      expect(record.verify_sign_in_code(nil, token: result.token)).to be_invalid
    end

    it "strips surrounding whitespace from the submitted code" do
      result = record.issue_sign_in_code!
      code   = record.last_delivered_sign_in_code
      expect(record.verify_sign_in_code("  #{code}  ", token: result.token)).to be_ok
    end

    it "returns false when sign_in_locked?" do
      result = record.issue_sign_in_code!
      code   = record.last_delivered_sign_in_code
      record.update!(sign_in_locked_at: 1.minute.ago)
      expect(record.verify_sign_in_code(code, token: result.token)).to be_locked
    end

    it "locks the credential after max_attempts wrong codes" do
      max = Vouch.configuration.magic_linkable.max_attempts
      result = record.issue_sign_in_code!
      max.times { record.verify_sign_in_code("000000", token: result.token) }
      expect(record.reload.sign_in_locked_at).to be_present
    end

    it "returns cancelled without retaining a threshold attempt when the host cancels the lock write" do
      config = Vouch.configuration.magic_linkable
      previous_max_attempts = config.max_attempts
      callback = :cancel_sign_in_lockout
      config.max_attempts = 1
      PhoneVerification.define_method(callback) do
        raise ActiveRecord::Rollback if will_save_change_to_sign_in_locked_at?
      end
      PhoneVerification.set_callback(:update, :before, callback)

      result = record.issue_sign_in_code!

      expect(record.verify_sign_in_code("000000", token: result.token)).to be_cancelled
      expect(record.reload).to have_attributes(sign_in_attempts: 0, sign_in_locked_at: nil)
    ensure
      config.max_attempts = previous_max_attempts if config
      PhoneVerification.skip_callback(:update, :before, callback) if callback
      PhoneVerification.remove_method(callback) if callback && PhoneVerification.method_defined?(callback)
    end

    it "does NOT set verified_at (that's Verifiable's concern)" do
      result = record.issue_sign_in_code!
      code   = record.last_delivered_sign_in_code
      record.verify_sign_in_code(code, token: result.token)
      expect(record.reload.verified_at).to be_nil
    end

    it "returns false when the token payload's id does not match the record" do
      other  = PhoneVerification.create!(e164: "+15550002222")
      result = other.issue_sign_in_code!
      expect(record.verify_sign_in_code(other.last_delivered_sign_in_code, token: result.token)).to be_invalid
    end

    it "rejects a sign-in challenge after the contact subject changes" do
      result = record.issue_sign_in_code!
      code = record.last_delivered_sign_in_code
      record.update!(e164: "+15550009998")

      expect(record.verify_sign_in_code(code, token: result.token)).to be_invalid
    end
  end

  describe "attempt counters are independent from Verifiable" do
    it "wrong sign-in codes don't bump verification_attempts" do
      result = record.issue_sign_in_code!
      record.verify_sign_in_code("000000", token: result.token)
      expect(record.reload.verification_attempts).to eq(0)
    end

    it "wrong verify codes don't bump sign_in_attempts" do
      result = record.start_verification!
      record.complete_verification!("000000", token: result.token)
      expect(record.reload.sign_in_attempts).to eq(0)
    end
  end
end
