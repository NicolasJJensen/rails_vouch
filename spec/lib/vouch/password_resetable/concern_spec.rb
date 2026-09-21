# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::PasswordResetable::Concern do
  let(:account) { create(:account) }

  describe "#generate_password_reset_token!" do
    it "generates a raw token and stores only its digest" do
      token = account.generate_password_reset_token!.value
      expect(token).to be_a(String)
      expect(token).not_to be_empty
      expect(account.reload.password_reset_token_digest).not_to eq(token)
    end
  end

  describe ".find_by_auth_password_reset_token" do
    it "finds the account from a valid token" do
      token = account.generate_password_reset_token!.value
      found = Account.find_by_auth_password_reset_token(token)
      expect(found).to eq(account)
    end

    it "returns nil for a tampered token" do
      result = Account.find_by_auth_password_reset_token("tampered-invalid-token")
      expect(result).to be_nil
    end

    it "returns nil for non-string tokens without affecting an issued token" do
      token = account.generate_password_reset_token!.value

      [123, ["invalid-token"], {"token" => "invalid-token"}].each do |invalid_token|
        expect(Account.find_by_auth_password_reset_token(invalid_token)).to be_nil
        expect(Account.find_by_auth_password_reset_token(token)).to eq(account)
      end
    end

    it "returns nil for an expired token" do
      # Password reset expiry is 15 minutes
      token = account.generate_password_reset_token!.value

      travel 20.minutes do
        result = Account.find_by_auth_password_reset_token(token)
        expect(result).to be_nil
      end
    end

    it "finds the account within the expiry window" do
      token = account.generate_password_reset_token!.value

      travel 10.minutes do
        result = Account.find_by_auth_password_reset_token(token)
        expect(result).to eq(account)
      end
    end
  end

  describe "#reset_password_with_token!" do
    it "does not consume a token when no new password is supplied" do
      token = account.generate_password_reset_token!.value

      expect(account.reset_password_with_token!(token)).to be_invalid
      expect(Account.find_by_auth_password_reset_token(token)).to eq(account)
    end

    it "rejects non-string tokens without changing the password or consuming an issued token" do
      token = account.generate_password_reset_token!.value
      original_digest = account.password_digest

      [123, ["invalid-token"], {"token" => "invalid-token"}].each do |invalid_token|
        expect(account.reset_password_with_token!(invalid_token, password: "replacement123")).to be_invalid
        expect(account.reload.password_digest).to eq(original_digest)
        expect(Account.find_by_auth_password_reset_token(token)).to eq(account)
      end
    end

    it "rejects non-password attributes without consuming the token" do
      token = account.generate_password_reset_token!.value
      original_email = account.email_address

      expect {
        account.reset_password_with_token!(token,
          password: "replacement123",
          email_address: "changed@example.com")
      }.to raise_error(ArgumentError, /unsupported reset attributes: email_address/)

      expect(account.reload.email_address).to eq(original_email)
      expect(Account.find_by_auth_password_reset_token(token)).to eq(account)
      expect(account.reset_password_with_token!(token, password: "replacement123")).to be_ok
      expect(account.reload.authenticate("replacement123")).to be_truthy
    end

    it "continues to infer a missing password confirmation" do
      token = account.generate_password_reset_token!.value

      expect(account.reset_password_with_token!(token, password: "replacement123")).to be_ok
      expect(account.reload.authenticate("replacement123")).to be_truthy
    end
  end

end
