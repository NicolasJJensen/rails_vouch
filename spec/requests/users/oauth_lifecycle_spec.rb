require "rails_helper"
require "omniauth"

RSpec.describe "OAuth profile updates during authentication", type: :request do
  let(:account) { create(:account, email_address: "oauth-before@example.com") }
  let!(:identity) { create(:user, account: account) }
  let!(:oauth_identity) { OmniAuthIdentity.create!(account: account, provider: "google_oauth2", uid: "lifecycle") }
  let(:auth_hash) do
    OmniAuth::AuthHash.new(provider: "google_oauth2", uid: "lifecycle",
      info: {email: "oauth-after@example.com"})
  end

  before do
    @original_hooks = [Users::OmniAuthsController, Users::MembershipSessionsController,
      Users::TwoFactorChallengeController].to_h { |klass| [klass, klass.__hooks] }
    allow_any_instance_of(Account).to receive(:oauth_attributes_for_update) do |_account, auth|
      {email_address: auth.info.email}
    end
  end

  after { @original_hooks.each { |klass, hooks| klass.__hooks = hooks } }

  def callback
    get "/users/auth/google_oauth2/callback", env: {"omniauth.auth" => auth_hash}
  end

  it "does not update the profile when a before hook aborts sign-in" do
    Users::OmniAuthsController.before_oauth_sign_in { throw :abort }
    callback
    expect(response).to redirect_to("/users/sign_in")
    expect(account.reload.email_address).to eq("oauth-before@example.com")
    get "/users/two_factor_credentials"
    expect(response).to redirect_to("/users/sign_in")
  end

  it "raises after publishing when an after hook cancels sign-in" do
    Users::OmniAuthsController.after_oauth_sign_in { raise ActiveRecord::Rollback }
    expect { callback }.to raise_error(ActiveRecord::Rollback)
    expect(account.reload.email_address).to eq("oauth-after@example.com")
  end

  it "keeps the profile update when an MFA after hook cancels sign-in" do
    account.update!(failed_attempts: 3)
    credential = account.two_factor_credentials.create!(verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    delivered = nil
    allow_any_instance_of(TwoFactorCredential).to receive(:deliver_two_factor_code) { |_record, code| delivered = code }
    Users::TwoFactorChallengeController.after_oauth_sign_in { raise ActiveRecord::Rollback }

    callback
    expect(response).to redirect_to("/users/two_factor_challenges")
    get "/users/two_factor_challenges/#{credential.id}"
    expect { patch "/users/two_factor_challenges/#{credential.id}", params: {code: delivered} }
      .to raise_error(ActiveRecord::Rollback)

    expect(account.reload.email_address).to eq("oauth-after@example.com")
  end

  it "updates the profile inside the lifecycle before publishing authentication" do
    observed = []
    Users::OmniAuthsController.after_oauth_sign_in do |owner, _identity|
      observed << [owner.reload.email_address, current_identity]
    end
    callback
    expect(response).to redirect_to("/")
    expect(observed.first.first).to eq("oauth-after@example.com")
    expect(observed.first.last).to be_present
    get "/users/two_factor_credentials"
    expect(response).to have_http_status(:ok)
  end

  it "defers the update until both MFA and identity selection complete" do
    create(:user, account: account)
    credential = account.two_factor_credentials.create!(verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    delivered = nil
    allow_any_instance_of(TwoFactorCredential).to receive(:deliver_two_factor_code) { |_record, code| delivered = code }
    callback
    expect(response).to redirect_to("/users/two_factor_challenges")
    expect(account.reload.email_address).to eq("oauth-before@example.com")
    get "/users/two_factor_challenges/#{credential.id}"
    patch "/users/two_factor_challenges/#{credential.id}", params: {code: delivered}
    expect(response).to redirect_to("/users/select")
    expect(account.reload.email_address).to eq("oauth-before@example.com")
    post "/users/select", params: {identity_id: identity.id}
    expect(response).to redirect_to("/")
    expect(account.reload.email_address).to eq("oauth-after@example.com")
    get "/users/two_factor_credentials"
    expect(response).to have_http_status(:ok)
  end

  it "keeps a large provider profile out of an MFA-pending cookie session" do
    credential = account.two_factor_credentials.create!(verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    allow_any_instance_of(TwoFactorCredential).to receive(:deliver_two_factor_code)
    auth_hash.info.name = "OAuth Member"
    auth_hash.info.bio = "x" * 5_000

    callback

    expect(response).to redirect_to("/users/two_factor_challenges")
  end

  it "keeps a large provider profile out of an identity-selection cookie session" do
    create(:user, account: account)
    auth_hash.info.name = "OAuth Member"
    auth_hash.info.bio = "x" * 5_000

    callback

    expect(response).to redirect_to("/users/select")
  end

  it "does not refresh the profile when a selection hook aborts" do
    create(:user, account: account)
    Users::MembershipSessionsController.before_oauth_sign_in { throw :abort }
    callback
    expect(response).to redirect_to("/users/select")
    post "/users/select", params: {identity_id: identity.id}
    expect(response).to redirect_to("/users/sign_in")
    expect(account.reload.email_address).to eq("oauth-before@example.com")
  end

  it "denies completion when a model callback cancels the profile update" do
    cancellation = proc { raise ActiveRecord::Rollback if saved_change_to_email_address? }
    Account.set_callback(:update, :after, cancellation)
    callback
    expect(response).to redirect_to("/users/sign_in")
    expect(account.reload.email_address).to eq("oauth-before@example.com")
    get "/users/two_factor_credentials"
    expect(response).to redirect_to("/users/sign_in")
  ensure
    Account.skip_callback(:update, :after, cancellation) if cancellation
  end

  it "handles profile validation failure after identity selection" do
    create(:user, account: account)
    auth_hash.info.email = "invalid-address"
    callback
    expect(response).to redirect_to("/users/select")
    post "/users/select", params: {identity_id: identity.id}
    expect(response).to redirect_to("/users/sign_in")
    expect(account.reload.email_address).to eq("oauth-before@example.com")
    get "/users/two_factor_credentials"
    expect(response).to redirect_to("/users/sign_in")
  end
end
