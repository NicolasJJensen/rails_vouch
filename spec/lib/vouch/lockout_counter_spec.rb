# frozen_string_literal: true

require "rails_helper"

# LockoutCounter is a private mixin shared by Verifiable, TwoFactorable and
# Recoverable. We exercise the helpers via a thin test class rather than
# re-testing through each consumer — keeps the contract explicit.
RSpec.describe Vouch::LockoutCounter do
  # Reuse PhoneVerification: it includes Verifiable, which includes this
  # module. The fields we want exist on the row, the `with_lock` block
  # gets a real ActiveRecord row, and we don't have to invent a fake AR
  # class just for the test.
  let(:record) { PhoneVerification.create!(e164: "+15550009999") }

  describe "#consume_otp_token" do
    let(:purpose) { "vouch.verify.PhoneVerification.#{record.id}.test" }

    it "returns the payload on a successful consume" do
      # Issue a real token, then round-trip it through the helper.
      issued = OtpCourier::OTP.issue(
        purpose:  purpose,
        payload:  { "id" => record.id.to_s, "klass" => "PhoneVerification" }
      )
      payload = record.send(:consume_otp_token, issued.token, issued.code, purpose)
      expect(payload).to include("id" => record.id.to_s, "klass" => "PhoneVerification")
    end

    it "returns nil for a garbage token" do
      expect(record.send(:consume_otp_token, "not-a-token", "123456", purpose)).to be_nil
    end

    it "propagates unexpected otp_courier errors" do
      allow(OtpCourier::OTP).to receive(:consume).and_raise(StandardError, "boom")
      expect { record.send(:consume_otp_token, "tok", "123456", purpose) }
        .to raise_error(StandardError, "boom")
    end
  end

  describe "#bump_lockout_counter!" do
    it "increments the counter on each call" do
      expect {
        record.send(:bump_lockout_counter!,
                    counter_attr:   :verification_attempts,
                    locked_at_attr: :verification_locked_at,
                    max_attempts:   5,
                    lockout_duration: 30.minutes)
      }.to change { record.reload.verification_attempts }.from(0).to(1)
    end

    it "does not set locked_at until the counter reaches max_attempts" do
      4.times do
        record.send(:bump_lockout_counter!,
                    counter_attr:   :verification_attempts,
                    locked_at_attr: :verification_locked_at,
                    max_attempts:   5,
                    lockout_duration: 30.minutes)
      end
      expect(record.reload.verification_locked_at).to be_nil
    end

    it "keeps below-threshold increments callback-free" do
      callback = :reject_lockout_counter_update
      PhoneVerification.define_method(callback) { raise "unexpected callback" }
      PhoneVerification.set_callback(:update, :before, callback)

      record.send(:bump_lockout_counter!,
                  counter_attr:   :verification_attempts,
                  locked_at_attr: :verification_locked_at,
                  max_attempts:   2,
                  lockout_duration: 30.minutes)

      expect(record.reload).to have_attributes(verification_attempts: 1, verification_locked_at: nil)
    ensure
      PhoneVerification.skip_callback(:update, :before, callback) if callback
      PhoneVerification.remove_method(callback) if callback && PhoneVerification.method_defined?(callback)
    end

    it "sets locked_at exactly when the counter crosses max_attempts" do
      5.times do
        record.send(:bump_lockout_counter!,
                    counter_attr:   :verification_attempts,
                    locked_at_attr: :verification_locked_at,
                    max_attempts:   5,
                    lockout_duration: 30.minutes)
      end
      expect(record.reload.verification_locked_at).to be_present
    end

    it "restarts an expired lockout window" do
      record.update!(verification_attempts: 5, verification_locked_at: 31.minutes.ago)

      record.send(:bump_lockout_counter!,
                  counter_attr:   :verification_attempts,
                  locked_at_attr: :verification_locked_at,
                  max_attempts:   5,
                  lockout_duration: 30.minutes)

      record.reload
      expect(record.verification_attempts).to eq(6)
      expect(record.verification_locked_at).to be > 31.minutes.ago
    end
  end

  describe "#locked_window_open?" do
    it "returns false when the locked_at column is nil" do
      expect(record.send(:locked_window_open?,
                         locked_at_attr:   :verification_locked_at,
                         lockout_duration: 30.minutes)).to be false
    end

    it "returns true when locked_at is within the window" do
      record.update!(verification_locked_at: 1.minute.ago)
      expect(record.send(:locked_window_open?,
                         locked_at_attr:   :verification_locked_at,
                         lockout_duration: 30.minutes)).to be true
    end

    it "returns false once the window has elapsed" do
      record.update!(verification_locked_at: 31.minutes.ago)
      expect(record.send(:locked_window_open?,
                         locked_at_attr:   :verification_locked_at,
                         lockout_duration: 30.minutes)).to be false
    end

    it "treats exactly-at-the-boundary as closed (decision 49)" do
      freeze_time do
        record.update!(verification_locked_at: 30.minutes.ago)
        expect(record.send(:locked_window_open?,
                           locked_at_attr:   :verification_locked_at,
                           lockout_duration: 30.minutes)).to be false
      end
    end
  end

  describe "#payload_valid?" do
    it "returns true for a payload with matching id and klass" do
      payload = { "id" => record.id.to_s, "klass" => "PhoneVerification" }
      expect(record.send(:payload_valid?, payload)).to be true
    end

    it "returns false when the id does not match" do
      payload = { "id" => "9999", "klass" => "PhoneVerification" }
      expect(record.send(:payload_valid?, payload)).to be false
    end

    it "returns false when the klass does not match (anti-confusion / STI guard)" do
      payload = { "id" => record.id.to_s, "klass" => "OtherClass" }
      expect(record.send(:payload_valid?, payload)).to be false
    end

    it "returns false for nil" do
      expect(record.send(:payload_valid?, nil)).to be false
    end

    it "returns false for a non-hash payload" do
      expect(record.send(:payload_valid?, "not-a-hash")).to be false
    end

    it "compares id as a string (PK-agnostic per decision 28)" do
      payload = { "id" => record.id, "klass" => "PhoneVerification" } # integer
      expect(record.send(:payload_valid?, payload)).to be true
    end
  end
end
