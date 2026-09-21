# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::Recoverable do
  let(:account) { create(:account) }

  describe "association" do
    it "exposes vouch_recovery_codes as a polymorphic has_many" do
      expect(account).to respond_to(:vouch_recovery_codes)
      reflection = Account.reflect_on_association(:vouch_recovery_codes)
      expect(reflection.options[:as]).to eq(:recoverable)
      expect(reflection.options[:dependent]).to eq(:destroy)
    end

    it "destroys recovery codes when the host row is destroyed" do
      account.generate_recovery_codes!
      expect { account.destroy }.to change(Vouch::RecoveryCode, :count).by(-10)
    end
  end

  describe "#recovery_locked?" do
    it "returns false when recovery_locked_at is nil" do
      expect(account.recovery_locked?).to be false
    end

    it "returns true inside the lockout window" do
      account.update!(recovery_locked_at: 1.minute.ago)
      expect(account.recovery_locked?).to be true
    end

    it "returns false after the lockout window elapses" do
      account.update!(recovery_locked_at: 31.minutes.ago)
      expect(account.recovery_locked?).to be false
    end
  end

  describe "#generate_recovery_codes!" do
    it "returns the configured number of plaintext codes" do
      codes = account.generate_recovery_codes!.value
      expect(codes.length).to eq(Vouch.configuration.recoverable.code_count)
    end

    it "formats codes with a hyphen in the middle" do
      codes = account.generate_recovery_codes!.value
      codes.each do |code|
        expect(code).to match(/\A[A-Z0-9]+-[A-Z0-9]+\z/)
      end
    end

    it "draws codes from the Crockford alphabet (no I, L, O, U, 0, 1)" do
      codes = account.generate_recovery_codes!.value
      banned = %w[I L O U 0 1]
      codes.each do |code|
        plaintext = code.delete("-")
        expect(plaintext.chars & banned).to be_empty
      end
    end

    it "persists one row per code, BCrypt-hashed" do
      account.generate_recovery_codes!
      stored = account.vouch_recovery_codes
      expect(stored.length).to eq(Vouch.configuration.recoverable.code_count)
      stored.each do |row|
        expect(row.code_digest).to match(/\A\$2[ab]\$/) # BCrypt prefix
        expect(row.used_at).to be_nil
      end
    end

    it "replaces any existing codes when called again" do
      first_codes  = account.generate_recovery_codes!.value
      first_ids    = account.vouch_recovery_codes.pluck(:id)
      second_codes = account.generate_recovery_codes!.value
      second_ids   = account.vouch_recovery_codes.pluck(:id)

      expect(second_codes).not_to eq(first_codes)
      expect(second_ids & first_ids).to be_empty
    end

    it "resets recovery_attempts and recovery_locked_at" do
      account.update!(recovery_attempts: 4, recovery_locked_at: 1.minute.ago)
      account.generate_recovery_codes!
      expect(account.reload.recovery_attempts).to eq(0)
      expect(account.recovery_locked_at).to be_nil
    end
  end

  describe "#consume_recovery_code!" do
    let!(:codes) { account.generate_recovery_codes!.value }

    it "returns true on a correct code and marks the row used" do
      code = codes.first
      expect(account.consume_recovery_code!(code)).to be_ok

      digest_match = account.vouch_recovery_codes
                            .where.not(used_at: nil)
                            .find { |row| BCrypt::Password.new(row.code_digest) == code.delete("-") }
      expect(digest_match).to be_present
    end

    it "decreases recovery_codes_remaining by 1 on success" do
      expect { account.consume_recovery_code!(codes.first) }
        .to change { account.recovery_codes_remaining }.by(-1)
    end

    it "returns false on the second use of the same code" do
      code = codes.first
      account.consume_recovery_code!(code)
      expect(account.consume_recovery_code!(code)).to be_invalid
    end

    it "returns false on a code that was never issued" do
      expect(account.consume_recovery_code!("XXXX-XXXX")).to be_invalid
    end

    it "returns false on blank input without raising" do
      expect(account.consume_recovery_code!("")).to be_invalid
      expect(account.consume_recovery_code!(nil)).to be_invalid
      expect(account.consume_recovery_code!("   ")).to be_invalid
    end

    it "accepts codes with arbitrary whitespace (handles wrapped mail)" do
      code = codes.first
      noisy = "  #{code[0, 2]} #{code[2, 2]}-#{code[5, 2]} #{code[7, 2]}  "
      expect(account.consume_recovery_code!(noisy)).to be_ok
    end

    it "accepts lowercase input" do
      code = codes.first
      expect(account.consume_recovery_code!(code.downcase)).to be_ok
    end

    it "accepts a code without hyphens" do
      code = codes.first
      expect(account.consume_recovery_code!(code.delete("-"))).to be_ok
    end

    it "resets recovery_attempts on success" do
      account.update!(recovery_attempts: 3)
      account.consume_recovery_code!(codes.first)
      expect(account.reload.recovery_attempts).to eq(0)
    end

    it "increments recovery_attempts on failure" do
      expect { account.consume_recovery_code!("WRONG-CODE") }
        .to change { account.reload.recovery_attempts }.by(1)
    end

    it "locks the host after max_attempts failed codes" do
      max = Vouch.configuration.recoverable.max_attempts
      max.times { account.consume_recovery_code!("WRONG-CODE") }
      expect(account.reload.recovery_locked_at).to be_present
    end

    it "returns false when recovery_locked?" do
      account.update!(recovery_locked_at: 1.minute.ago)
      expect(account.consume_recovery_code!(codes.first)).to be_locked
    end
  end

  describe "#recovery_codes_remaining" do
    it "is 0 when no codes have been generated" do
      expect(account.recovery_codes_remaining).to eq(0)
    end

    it "matches the count of unused codes" do
      account.generate_recovery_codes!
      expect(account.recovery_codes_remaining).to eq(
        Vouch.configuration.recoverable.code_count
      )
    end
  end

  describe "#recovery_codes_low?" do
    let(:low_threshold) { Vouch.configuration.recoverable.low_threshold }

    it "is true when no codes exist" do
      expect(account.recovery_codes_low?).to be true
    end

    it "is false right after generation" do
      account.generate_recovery_codes!
      expect(account.recovery_codes_low?).to be false
    end

    it "flips to true once remaining drops below the threshold" do
      codes = account.generate_recovery_codes!.value
      # Consume until we're below the threshold.
      to_use = codes.length - low_threshold + 1
      codes.first(to_use).each { |c| account.consume_recovery_code!(c) }
      expect(account.recovery_codes_low?).to be true
    end
  end
end
