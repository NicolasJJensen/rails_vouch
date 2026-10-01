require "rails_helper"

RSpec.describe "Password reset eligibility", type: :request do
  let!(:account) { create(:account) }

  it "does not issue a reset for an account without a password" do
    account.update_columns(password_digest: nil)
    post "/users/password_reset", params: { email_address: account.email_address }
    expect(response).to redirect_to("/users/sign_in")
    expect(account.reload.password_reset_token_digest).to be_nil
  end

  it "does not issue or accept resets for an unfinished invited account" do
    token = account.generate_password_reset_token!.value
    account.update!(registration_required: true)
    get "/users/password_reset/edit", params: { token: token }
    expect(response).to redirect_to("/users/sign_in")
    post "/users/password_reset", params: { email_address: account.email_address }
    expect(Account.find_by_auth_password_reset_token(token)).to eq(account)
  end

  it "rechecks eligibility after a reset was issued" do
    token = account.generate_password_reset_token!.value
    account.update_columns(password_digest: nil)
    patch "/users/password_reset", params: { token: token, account: { password: "newpassword1" } }
    expect(response).to redirect_to("/users/sign_in")
    expect(account.reload.password_digest).to be_nil
  end

  it "rejects an unsaved resolver result" do
    allow(Account).to receive(:first_by_auth_conditions).and_return(Account.new(email_address: account.email_address))
    post "/users/password_reset", params: { email_address: account.email_address }
    expect(response).to redirect_to("/users/sign_in")
    expect(account.reload.password_reset_token_digest).to be_nil
  end

  it "rejects a resolver result from another mapped model" do
    allow(Account).to receive(:first_by_auth_conditions).and_return(create(:user, account: account))
    post "/users/password_reset", params: { email_address: account.email_address }
    expect(response).to redirect_to("/users/sign_in")
    expect(account.reload.password_reset_token_digest).to be_nil
  end

  it "refetches resolver results inside the host eligibility relation" do
    allow(Account).to receive(:first_by_auth_conditions).and_return(account)
    allow_any_instance_of(Users::PasswordResetsController).to receive(:password_reset_accounts).and_return(Account.none)
    post "/users/password_reset", params: { email_address: account.email_address }
    expect(response).to redirect_to("/users/sign_in")
    expect(account.reload.password_reset_token_digest).to be_nil
  end

  it "passes the recipient captured during issuance to delivery" do
    captured = nil
    allow_any_instance_of(Users::PasswordResetsController).to receive(:run_hooks) do |_controller, hook, record, token, recipient|
      next unless hook == :password_reset_token_generation
      captured = [recipient, token]
      record.update!(email_address: "changed@example.com")
    end
    original_email = account.email_address
    post "/users/password_reset", params: { email_address: original_email }
    expect(captured.first).to eq(original_email)
    expect(Account.find_by_auth_password_reset_token(captured.last)).to be_nil
  end

  it "keeps a delivery failure private and reports it internally" do
    error = IOError.new("delivery unavailable")
    allow_any_instance_of(Users::PasswordResetsController).to receive(:run_hooks).with(:password_reset_token_generation, anything, anything, anything).and_raise(error)
    expect(Rails.error).to receive(:report).with(error, handled: true)
    post "/users/password_reset", params: { email_address: account.email_address }
    expect(response).to redirect_to("/users/sign_in")
    expect(flash[:notice]).to eq(I18n.t("vouch.passwords.reset_sent"))
  end
end
