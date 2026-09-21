# frozen_string_literal: true

require "rails_helper"

# H15: Session fingerprint invalidation.
#
# The Warden serializer stores a fragment of the password digest alongside
# the identity id. A password change rotates the digest, so any session
# whose stored fingerprint no longer matches the current digest must be
# treated as logged out on the very next request.
RSpec.describe "Session fingerprint invalidation", type: :request do
  let(:organisation) { create(:organisation) }
  let(:account)      { create(:account, email_address: "fp@example.com", password: "password123", password_confirmation: "password123") }
  let!(:user)        { create(:user, account: account, organisation: organisation) }

  around do |example|
    original = Vouch.configuration.lockable.invalidate_sessions_on_lockout
    example.run
  ensure
    Vouch.configuration.lockable.invalidate_sessions_on_lockout = original
  end

  it "rejects requests whose serialized fingerprint no longer matches" do
    post "/users/sign_in", params: { email_address: "fp@example.com", password: "password123" }
    expect(response).to redirect_to("/")

    # Rotate the account's password out-of-band — this is what a "change
    # password" action in another session does to the persisted digest.
    account.update!(password: "newpassword456", password_confirmation: "newpassword456")

    # The cookie from before still references the old digest fingerprint,
    # so Warden should drop the identity on the next request.
    get "/users/sign_in"
    expect(response).to have_http_status(:ok)
  end

  it "keeps an established identity session after lockout by default" do
    post "/users/sign_in", params: { email_address: "fp@example.com", password: "password123" }
    account.update!(locked_at: Time.current, failed_attempts: 5)

    get "/users/two_factor_credentials"

    expect(response).to have_http_status(:ok)
    expect(request.env["action_controller.instance"].send(:current_identity)).to eq(user)
  end

  it "drops an established identity session after lockout when configured" do
    Vouch.configuration.lockable.invalidate_sessions_on_lockout = true
    post "/users/sign_in", params: { email_address: "fp@example.com", password: "password123" }
    account.update!(locked_at: Time.current, failed_attempts: 5)

    get "/users/two_factor_credentials"

    expect(response).to redirect_to("/users/sign_in")
  end

  it "drops a pending account session after lockout when configured" do
    Vouch.configuration.lockable.invalidate_sessions_on_lockout = true
    sign_in_as_account(account)
    get "/users/select"
    expect(response).to have_http_status(:ok)

    account.update!(locked_at: Time.current, failed_attempts: 5)

    get "/users/select"

    expect(response).to redirect_to("/users/sign_in")
  end
end
