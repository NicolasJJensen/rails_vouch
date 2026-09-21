# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::Lockable::Concern do
  let(:account) { create(:account) }

  describe "#locked?" do
    context "when locked_at is nil" do
      it "returns false" do
        expect(account.locked?).to be false
      end
    end

    context "when locked within the duration window" do
      before { account.update!(locked_at: 1.minute.ago) }

      it "returns true" do
        expect(account.locked?).to be true
      end
    end

    context "when the lock has expired" do
      before { account.update!(locked_at: 10.minutes.ago) }

      it "returns false" do
        expect(account.locked?).to be false
      end
    end
  end

  describe "#lock_account!" do
    it "sets locked_at" do
      account.lock_account!
      expect(account.reload.locked_at).to be_present
    end
  end

  describe "#failed_login!" do
    it "increments failed_attempts" do
      expect { account.failed_login! }.to change { account.reload.failed_attempts }.by(1)
    end

    it "locks the account after reaching the threshold" do
      (Account.auth_config(:lockable, :max_failed_attempts) - 1).times { account.failed_login! }
      expect(account.locked?).to be false

      account.failed_login!
      expect(account.reload.locked?).to be true
    end

    context "when lock strategy is not :failed_attempts" do
      before do
        allow(account).to receive(:auth_config).and_call_original
        allow(account).to receive(:auth_config).with(:lockable, :strategy).and_return(:none)
      end

      it "does not lock the account" do
        10.times { account.failed_login! }
        expect(account.reload.locked?).to be false
      end
    end

    context "when already locked" do
      before do
        account.update!(failed_attempts: Account.auth_config(:lockable, :max_failed_attempts), locked_at: 2.minutes.ago)
      end

      it "does not reset locked_at" do
        original_locked_at = account.locked_at

        account.failed_login!

        expect(account.reload.locked_at).to be_within(1.second).of(original_locked_at)
      end
    end
  end

  describe "#successful_login!" do
    before { account.update!(locked_at: Time.current, failed_attempts: 5) }

    it "resets failed_attempts to 0" do
      account.successful_login!
      expect(account.reload.failed_attempts).to eq(0)
    end

    it "clears locked_at" do
      account.successful_login!
      expect(account.reload.locked_at).to be_nil
    end
  end

  describe "#current_lockout_duration" do
    context "on first lock" do
      before { account.update!(failed_attempts: 5) }

      it "returns the base duration" do
        expect(account.current_lockout_duration).to eq(5.minutes)
      end
    end

    context "on second lock" do
      before { account.update!(failed_attempts: 6, consecutive_locks: 2) }

      it "doubles the duration" do
        expect(account.current_lockout_duration).to eq(10.minutes)
      end
    end

    context "beyond the exponent cap" do
      before { account.update!(failed_attempts: 5 * 300, consecutive_locks: 300) }

      it "caps at MAX_LOCKOUT_EXPONENT" do
        max_duration = 5.minutes * (2**8)
        expect(account.current_lockout_duration).to eq(max_duration)
      end
    end

    context "when lock_after is 0" do
      before do
        allow(account).to receive(:auth_config).and_call_original
        allow(account).to receive(:auth_config).with(:lockable, :max_failed_attempts).and_return(0)
      end

      it "returns the base duration without dividing by zero" do
        expect { account.current_lockout_duration }.not_to raise_error
      end
    end
  end

  describe "#lockout_time_remaining" do
    context "when not locked" do
      it "returns 0" do
        expect(account.lockout_time_remaining).to eq(0)
      end
    end

    context "when locked" do
      before { account.update!(locked_at: 1.minute.ago, failed_attempts: 5) }

      it "returns the remaining time" do
        remaining = account.lockout_time_remaining
        expect(remaining).to be > 0
        expect(remaining).to be <= 5.minutes
      end
    end
  end
end
