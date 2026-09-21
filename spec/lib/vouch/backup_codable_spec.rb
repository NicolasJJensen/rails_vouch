# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::BackupCodable do
  let(:account)    { create(:account) }
  let(:credential) do
    TwoFactorCredential.create!(account: account, type: "totp",
      verified_at: Time.current, two_factor_enabled_at: Time.current)
  end

  describe "two-factor wrapper installation" do
    it "installs the wrapper regardless of concern inclusion order" do
      [
        [Vouch::TwoFactorable, Vouch::BackupCodable],
        [Vouch::BackupCodable, Vouch::TwoFactorable]
      ].each do |concerns|
        klass = Class.new(ActiveRecord::Base) do
          self.table_name = "two_factor_credentials"
        end
        concerns.each { |concern| klass.include(concern) }

        expect(klass.ancestors.count { |ancestor| ancestor == Vouch::BackupCodable::TwoFactorChallenge }).to eq(1)
      end
    end

    it "uses a backup proof when BackupCodable was included first" do
      klass = Class.new(ActiveRecord::Base) do
        self.table_name = "two_factor_credentials"
        self.inheritance_column = nil

        belongs_to :account
        has_many :backup_codes, class_name: "BackupCode", foreign_key: :two_factor_credential_id

        include Vouch::BackupCodable
        include Vouch::TwoFactorable

        def deliver_two_factor_code(_code); end
      end
      stub_const("ReverseOrderBackupCredential", klass)
      record = klass.create!(account: account, two_factor_enabled_at: Time.current)
      code = record.regenerate_backup_codes!(count: 1).value.first

      expect(record.verify_challenge(code, token: "not-an-otp-token")).to be_ok
      expect(record.reload.backup_codes.where.not(used_at: nil).count).to eq(1)
    end
  end

  describe "#regenerate_backup_codes!" do
    it "creates the configured number of codes and returns them in plaintext" do
      count = Vouch.configuration.backup_codable.code_count
      codes = credential.regenerate_backup_codes!.value

      expect(codes.length).to eq(count)
      expect(codes).to all(be_a(String))
      expect(credential.backup_codes.count).to eq(count)
    end

    it "stores each code as a BCrypt digest, not plaintext" do
      codes = credential.regenerate_backup_codes!.value
      credential.backup_codes.each do |row|
        expect(row.code_digest).to match(/\A\$2[aby]\$/)
        expect(codes).not_to include(row.code_digest)
      end
    end

    it "replaces any existing set — used or unused codes are wiped" do
      first  = credential.regenerate_backup_codes!.value
      first_ids = credential.backup_codes.pluck(:id)

      second = credential.regenerate_backup_codes!.value

      expect(credential.backup_codes.pluck(:id)).not_to match_array(first_ids)
      expect(second).not_to match_array(first)
    end

    it "honours a per-call count override" do
      codes = credential.regenerate_backup_codes!(count: 3).value
      expect(codes.length).to eq(3)
      expect(credential.backup_codes.count).to eq(3)
    end
  end

  describe "#consume_backup_code!" do
    let!(:codes) { credential.regenerate_backup_codes!.value }

    it "returns true on a valid code and marks exactly one row used" do
      code = codes.first

      expect(credential.consume_backup_code!(code)).to be_ok
      expect(credential.backup_codes.where.not(used_at: nil).count).to eq(1)
    end

    it "returns false on a wrong code and doesn't mark anything used" do
      expect(credential.consume_backup_code!("00000000")).to be_invalid
      expect(credential.backup_codes.where.not(used_at: nil)).to be_empty
    end

    it "returns false on blank input without raising" do
      expect(credential.consume_backup_code!("")).to be_invalid
      expect(credential.consume_backup_code!(nil)).to be_invalid
    end

    it "strips surrounding whitespace from the submitted code" do
      code = codes.first
      expect(credential.consume_backup_code!("  #{code}  ")).to be_ok
    end

    it "won't reuse an already-used code" do
      code = codes.first
      credential.consume_backup_code!(code)
      expect(credential.consume_backup_code!(code)).to be_invalid
    end

    it "rolls back code consumption when recording factor success is cancelled" do
      callback = proc { raise ActiveRecord::Rollback }
      TwoFactorCredential.set_callback(:update, :before, callback)

      expect(credential.consume_backup_code!(codes.first)).to be_cancelled
      expect(credential.backup_codes.where.not(used_at: nil)).to be_empty
    ensure
      TwoFactorCredential.skip_callback(:update, :before, callback) if callback
    end

    it "does not consume a code while the factor is locked" do
      credential.update!(two_factor_locked_at: 1.minute.ago)

      expect(credential.consume_backup_code!(codes.first)).to be_locked
      expect(credential.backup_codes.where.not(used_at: nil)).to be_empty
    end

    it "does not consume a code while the factor is disabled" do
      credential.update!(two_factor_enabled_at: nil)

      expect(credential.consume_backup_code!(codes.first)).to be_locked
      expect(credential.backup_codes.where.not(used_at: nil)).to be_empty
    end

    it "does not consume a code while the factor is unverified" do
      credential.update!(verified_at: nil)

      expect(credential.consume_backup_code!(codes.first)).to be_locked
      expect(credential.backup_codes.where.not(used_at: nil)).to be_empty
    end

    it "rechecks eligibility after the owner row is locked" do
      flipped = false
      allow(credential).to receive(:lock!).and_wrap_original do |original, *args, **kwargs|
        unless flipped
          flipped = true
          credential.class.where(id: credential.id).update_all(two_factor_locked_at: 1.minute.ago)
        end
        original.call(*args, **kwargs)
      end

      expect(credential.consume_backup_code!(codes.first)).to be_locked
      expect(credential.backup_codes.where.not(used_at: nil)).to be_empty
    end

    it "enforces lock state for a TwoFactorable credential without Verifiable" do
      credential.singleton_class.send(:undef_method, :verified?)
      credential.update!(two_factor_locked_at: 1.minute.ago)

      expect(credential.consume_backup_code!(codes.first)).to be_locked
      expect(credential.backup_codes.where.not(used_at: nil)).to be_empty
    end

    it "keeps standalone BackupCodable hosts eligible without factor methods" do
      credential.singleton_class.send(:undef_method, :two_factor_locked?)
      credential.singleton_class.send(:undef_method, :two_factor_enabled?)
      credential.singleton_class.send(:undef_method, :verified?)

      expect(credential.consume_backup_code!(codes.first)).to be_ok
    end
  end

  describe "#verify_challenge with backup codes" do
    let!(:codes) { credential.regenerate_backup_codes!(count: 1).value }

    around do |example|
      config = Vouch.configuration.two_factorable
      previous = config.max_attempts
      config.max_attempts = 2
      example.run
    ensure
      config.max_attempts = previous
    end

    it "accepts a valid backup code before an invalid primary proof can lock the factor" do
      credential.update!(two_factor_failed_attempts: 1)

      expect(credential.verify_challenge(codes.first, token: "not-an-otp-token")).to be_ok

      credential.reload
      expect(credential.two_factor_failed_attempts).to eq(0)
      expect(credential.two_factor_locked_at).to be_nil
      expect(credential.two_factor_last_used_at).to be_present
      expect(credential.backup_codes.where.not(used_at: nil).count).to eq(1)
    end

    it "counts a failed backup and primary proof once" do
      expect(credential.verify_challenge("not-a-backup-code", token: "not-an-otp-token")).to be_invalid

      expect(credential.reload.two_factor_failed_attempts).to eq(1)
    end
  end

  describe "#backup_codes_remaining" do
    it "counts unused rows only" do
      codes = credential.regenerate_backup_codes!.value
      count = codes.length

      expect(credential.backup_codes_remaining).to eq(count)
      credential.consume_backup_code!(codes.first)
      expect(credential.backup_codes_remaining).to eq(count - 1)
    end
  end

  describe "#backup_codes_low?" do
    it "returns true when remaining < warn_at_remaining" do
      original = Vouch.configuration.backup_codable.warn_at_remaining
      Vouch.configuration.backup_codable.warn_at_remaining = 5

      codes = credential.regenerate_backup_codes!(count: 4).value
      expect(credential.backup_codes_low?).to be true
    ensure
      Vouch.configuration.backup_codable.warn_at_remaining = original
    end

    it "returns false when at or above the threshold" do
      original = Vouch.configuration.backup_codable.warn_at_remaining
      Vouch.configuration.backup_codable.warn_at_remaining = 3

      credential.regenerate_backup_codes!(count: 3)
      expect(credential.backup_codes_low?).to be false
    ensure
      Vouch.configuration.backup_codable.warn_at_remaining = original
    end
  end
end
