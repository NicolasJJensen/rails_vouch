# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Nullable credentials passwords" do
  it "saves a placeholder without a password and never authenticates it by password" do
    account = Account.create!(email_address: "pending@example.test", registration_required: true)
    expect(account.password_digest).to be_nil
    expect(account.authenticate("")).to be(false)
    expect(account.authenticate("anything")).to be(false)
  end

  it "retains native confirmation and byte-length errors for supplied passwords" do
    account = Account.new(email_address: "invalid@example.test", password: "first", password_confirmation: "second")
    expect(account).not_to be_valid
    expect(account.errors[:password_confirmation]).not_to be_empty
    account.password = "é" * 37
    account.password_confirmation = account.password
    expect(account).not_to be_valid
    expect(account.errors.of_kind?(:password, :password_too_long)).to be(true)
  end

  it "retains native password-challenge validation" do
    account = create(:account, password: "original", password_confirmation: "original")
    account.password = "replacement"
    account.password_challenge = "wrong"
    expect(account).not_to be_valid
    expect(account.errors[:password_challenge]).not_to be_empty
  end

  it "does not make unrelated host validations optional" do
    account = Account.new(email_address: "")
    expect(account).not_to be_valid
    expect(account.errors[:email_address]).not_to be_empty
  end

  it "builds an OAuth account without generating a password" do
    oauth = OmniAuth::AuthHash.new(provider: "example", uid: "123", info: { email: "oauth-only@example.test" })
    account = Account.new
    account.apply_oauth_registration(OmniAuthIdentity.new(provider: oauth.provider, uid: oauth.uid), auth_hash: oauth)
    expect(account.password).to be_nil
    expect(account.password_digest).to be_nil
    expect(account).to be_valid
  end
end
