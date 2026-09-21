# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::PasswordTrackable::Concern do
  let(:account) { create(:account) }

  describe "password archiving on update" do
    it "archives the old password digest when password changes" do
      old_digest = account.password_digest

      expect {
        account.update!(password: "newpassword1", password_confirmation: "newpassword1")
      }.to change { account.password_archives.count }.by(1)

      expect(account.password_archives.last.password_digest).to eq(old_digest)
    end

    it "does not archive when non-password fields change" do
      expect {
        account.update!(email_address: "changed@example.com")
      }.not_to change { account.password_archives.count }
    end

    it "does not archive when password_digest_before_last_save is nil (first save)" do
      # Build a new account (not yet saved)
      new_account = Account.new(
        email_address: "brand_new@example.com",
        password: "password123",
        password_confirmation: "password123"
      )

      # First save should not create a password archive
      expect {
        new_account.save!
      }.not_to change { PasswordArchive.count }
    end

    it "keeps an intervening password when a stale instance saves" do
      first = Account.find(account.id)
      second = Account.find(account.id)

      first.update!(password: "first-change-123", password_confirmation: "first-change-123")
      second.password = "second-change-123"
      second.password_confirmation = "second-change-123"
      second.save!

      archived_first_password = account.reload.password_archives.any? do |archive|
        BCrypt::Password.new(archive.password_digest) == "first-change-123"
      end
      expect(archived_first_password).to be true

      reusable = Account.find(account.id)
      expect(reusable.update(password: "first-change-123", password_confirmation: "first-change-123")).to be false
      expect(reusable.errors[:password]).to include("was used recently. Choose a different password.")
    end

    it "archives the current digest after standalone validation and a validation-skipping save" do
      stale = Account.find(account.id)
      stale.password = "first-change-123"
      stale.password_confirmation = "first-change-123"
      expect(stale).to be_valid

      account.update!(password: "second-change-123", password_confirmation: "second-change-123")
      stale.save!(validate: false)

      archived_second_password = account.reload.password_archives.any? do |archive|
        BCrypt::Password.new(archive.password_digest) == "second-change-123"
      end
      expect(archived_second_password).to be true
    end
  end

  describe "#password_not_recently_used" do
    it "rejects a recently used password" do
      original_password = account.password
      account.update!(password: "different123", password_confirmation: "different123")

      account.password = original_password
      account.password_confirmation = original_password
      expect(account).not_to be_valid
      expect(account.errors[:password]).to include("was used recently. Choose a different password.")
    end

    it "allows a password not in the archive" do
      account.update!(password: "secondpass1", password_confirmation: "secondpass1")
      account.password = "brandnewpass1"
      account.password_confirmation = "brandnewpass1"
      expect(account).to be_valid
    end
  end

  describe "archive pruning" do
    it "prunes archives beyond the history count" do
      # Create more archives than the history count (5)
      6.times do |i|
        account.update!(password: "password#{i}x", password_confirmation: "password#{i}x")
      end

      expect(account.password_archives.count).to be <= Account.auth_config(:password_trackable, :history_count)
    end

    it "prunes archives older than the history window" do
      # Create an old archive
      account.password_archives.create!(
        password_digest: BCrypt::Password.create("oldpass"),
        created_at: 2.months.ago
      )

      # Trigger pruning via a password change
      account.update!(password: "triggerprune1", password_confirmation: "triggerprune1")

      old_archives = account.password_archives.where("created_at < ?", Account.auth_config(:password_trackable, :history_window).ago)
      expect(old_archives.count).to eq(0)
    end
  end
end
