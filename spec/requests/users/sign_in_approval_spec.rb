require "rails_helper"

RSpec.describe "Host-requested sign-in approval", type: :request do
  let!(:user) { create(:user) }
  let(:account) { user.account }
  let!(:email) do
    account.two_factor_credentials.create!(type: "email", verified_at: Time.current)
  end
  let(:authenticator) do
    account.two_factor_credentials.create!(type: "totp", otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
  end
  let(:policy) { Vouch::AuthenticationPolicy.new }
  let(:codes) { {} }
  let(:pending_key) { Vouch::Session.key_for(:user, :two_factor) }
  let(:evidence_key) { Vouch::Session.key_for(:user, :evidence) }

  around do |example|
    original = Vouch.configuration.authentication_policy
    Vouch.configuration.authentication_policy = policy
    example.run
  ensure
    Vouch.configuration.authentication_policy = original
  end

  before do
    allow(policy).to receive(:sign_in_approval_required?).and_return(true)
    allow(policy).to receive(:sign_in_approval_credential) { account.two_factor_credentials.find_by(id: email.id) }
    delivered = codes
    allow_any_instance_of(TwoFactorCredential).to receive(:deliver_two_factor_code) do |record, code|
      delivered[record.id] = code
    end
  end

  def sign_in_with_password
    post "/users/sign_in", params: { email_address: account.email_address, password: "password123" }
    expect(response).to redirect_to("/users/two_factor_challenges")
  end

  def answer_email(code: nil)
    get "/users/two_factor_challenges/#{email.id}"
    expect(response).to have_http_status(:ok)
    patch "/users/two_factor_challenges/#{email.id}", params: { code: code || codes.fetch(email.id) }
  end

  def answer_totp
    get "/users/two_factor_challenges/#{authenticator.id}"
    patch "/users/two_factor_challenges/#{authenticator.id}", params: { code: ROTP::TOTP.new(authenticator.otp_secret).now }
  end

  it "approves a sign-in without enabling either the contact or the account MFA preference" do
    sign_in_with_password
    expect(request.session["warden.user.user.key"]).to be_nil
    expect(request.session["warden.user.user_account.key"]).to be_nil
    answer_email

    expect(response).to redirect_to("/")
    expect(request.session[evidence_key].sole).to include("purpose" => "sign_in_approval", "credential_id" => email.id.to_s)
    expect(email.reload.two_factor_enabled_at).to be_nil
    expect(account.reload).not_to be_two_factor_enabled
    expect(request.session[pending_key]).to be_nil
    get "/users/two_factor_credentials"
    expect(response).to have_http_status(:ok)
  end

  it "asks the host once, using the original request, and retains its selected contact" do
    allow(policy).to receive(:sign_in_approval_required?) do |_record, controller:, **|
      controller.params[:approve] == "yes"
    end
    post "/users/sign_in", params: { email_address: account.email_address, password: "password123", approve: "yes" }
    expect(response).to redirect_to("/users/two_factor_challenges")
    allow(policy).to receive(:sign_in_approval_credential).and_return(nil)
    answer_email
    expect(response).to redirect_to("/")
    expect(policy).to have_received(:sign_in_approval_required?).once
    expect(policy).to have_received(:sign_in_approval_credential).once
  end

  it "does not bypass ordinary MFA when the host requires no approval" do
    authenticator
    account.enable_two_factor!
    allow(policy).to receive(:sign_in_approval_required?).and_return(false)
    sign_in_with_password
    answer_totp
    expect(response).to redirect_to("/")
    expect(request.session[evidence_key].sole["credential_id"]).to eq(authenticator.id.to_s)
  end

  it "retains TOTP proof while it requests a separate unenrolled email, then publishes both" do
    authenticator
    account.enable_two_factor!
    sign_in_with_password
    answer_totp
    expect(response).to redirect_to("/users/two_factor_challenges")
    expect(request.session[pending_key]["proofs"].size).to eq(1)
    expect(request.session["warden.user.user.key"]).to be_nil
    expect(request.session[evidence_key]).to be_nil
    answer_email
    expect(response).to redirect_to("/")
    expect(request.session[evidence_key].map { |proof| proof["credential_id"] }).to contain_exactly(email.id.to_s, authenticator.id.to_s)
  end

  it "does not offer the unenrolled email instead of required ordinary MFA" do
    authenticator
    account.enable_two_factor!
    sign_in_with_password
    get "/users/two_factor_challenges/#{email.id}"
    expect(response).to redirect_to("/users/two_factor_challenges")
    expect(codes).to be_empty
  end

  it "uses one challenge when ordinary MFA supplies the selected credential" do
    email.enable_two_factor!
    account.enable_two_factor!
    sign_in_with_password
    answer_email
    expect(response).to redirect_to("/")
    expect(request.session[evidence_key].size).to eq(1)
    expect(request.session[evidence_key].sole["purpose"]).to be_nil
  end

  it "lets the host accept ordinary TOTP proof in place of the selected contact" do
    authenticator
    account.enable_two_factor!
    allow(policy).to receive(:sign_in_approval_satisfied?) do |_record, evidence:, **|
      evidence["method"] == "two_factor" && evidence["credential_id"] == authenticator.id.to_s
    end
    sign_in_with_password
    answer_totp
    expect(response).to redirect_to("/")
    expect(codes).to be_empty
  end

  it "keeps approval pending after a recovery code satisfies ordinary MFA" do
    authenticator
    account.enable_two_factor!
    code = account.generate_recovery_codes!.value.first
    sign_in_with_password
    post "/users/recovery", params: { recovery_owner_type: "Account", recovery_code: code }
    expect(response).to redirect_to("/users/two_factor_challenges")
    answer_email
    expect(response).to redirect_to("/")
    expect(request.session[evidence_key].map { |proof| proof["method"] }).to contain_exactly("recovery_code", "two_factor")
    expect(flash[:notice]).to include("recovery code")
  end

  it "does not spend an account recovery code as a substitute for approval alone" do
    code = account.generate_recovery_codes!.value.first
    sign_in_with_password
    post "/users/recovery", params: { recovery_owner_type: "Account", recovery_code: code }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(account.recovery_codes_remaining).to eq(10)
    expect(request.session["warden.user.user.key"]).to be_nil
  end

  it "denies a required approval when the host has no eligible contact" do
    allow(policy).to receive(:sign_in_approval_credential).and_return(nil)
    post "/users/sign_in", params: { email_address: account.email_address, password: "password123" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(request.session[pending_key]).to be_nil
  end

  it "rejects another account's selected contact" do
    other = create(:account).two_factor_credentials.create!(verified_at: Time.current)
    allow(policy).to receive(:sign_in_approval_credential).and_return(other)
    post "/users/sign_in", params: { email_address: account.email_address, password: "password123" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(codes).to be_empty
  end

  it "does not accept an arbitrary verified contact from the same account" do
    other = account.two_factor_credentials.create!(verified_at: Time.current)
    sign_in_with_password
    get "/users/two_factor_challenges/#{other.id}"
    expect(response).to redirect_to("/users/two_factor_challenges")
    expect(codes).to be_empty
  end

  it "keeps an incorrect code pending and counts the failed submission" do
    sign_in_with_password
    answer_email(code: "invalid")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(email.reload.two_factor_failed_attempts).to eq(1)
    expect(request.session["warden.user.user.key"]).to be_nil
  end

  it "rejects a contact changed after the first factor" do
    sign_in_with_password
    email.update!(otp_secret: ROTP::Base32.random)
    get "/users/two_factor_challenges/#{email.id}"
    expect(response).to redirect_to("/users/sign_in")
    expect(request.session[pending_key]).to be_nil
  end

  it "expires the whole sign-in without extending it between challenges" do
    sign_in_with_password
    issued_at = request.session[pending_key]["issued_at"]
    travel 1.minute do
      get "/users/two_factor_challenges"
      expect(request.session[pending_key]["issued_at"]).to eq(issued_at)
    end
    travel Vouch.configuration.pending_authentication_ttl + 1.second do
      get "/users/two_factor_challenges/#{email.id}"
      expect(response).to redirect_to("/users/sign_in")
    end
  end

  it "does not carry accepted proof into a different account's sign-in" do
    authenticator
    account.enable_two_factor!
    sign_in_with_password
    answer_totp
    other_user = create(:user)
    other_email = other_user.account.two_factor_credentials.create!(verified_at: Time.current)
    allow(policy).to receive(:sign_in_approval_credential).and_return(other_email)
    post "/users/sign_in", params: { email_address: other_user.account.email_address, password: "password123" }
    expect(response).to redirect_to("/users/two_factor_challenges")
    expect(request.session[pending_key]["proofs"]).to be_nil
    expect(request.session[pending_key]["account_id"]).to eq(other_user.account.id.to_s)
  end

  it "rejects proof when the account changes before approval completes" do
    sign_in_with_password
    get "/users/two_factor_challenges/#{email.id}"
    account.update!(password: "replacement123", password_confirmation: "replacement123")
    patch "/users/two_factor_challenges/#{email.id}", params: { code: codes.fetch(email.id) }
    expect(response).to redirect_to("/users/sign_in")
    expect(request.session[pending_key]).to be_nil
  end

  it "revalidates the selected contact before publishing a membership" do
    create(:user, account: account)
    sign_in_with_password
    answer_email
    expect(response).to redirect_to("/users/select")
    email.destroy!
    post "/users/select", params: { identity_id: user.id }
    expect(response).to redirect_to("/users/sign_in")
    expect(request.session["warden.user.user.key"]).to be_nil
  end

  it "retains proof through membership selection and emits its event only after sign-in" do
    create(:user, account: account)
    events = []
    [Users::TwoFactorChallengeController, Users::MembershipSessionsController].each do |controller|
      allow_any_instance_of(controller).to receive(:run_hooks).and_wrap_original do |original, hook, *args, **kwargs, &block|
        events << kwargs[:evidence] if hook == :two_factor_verification
        original.call(hook, *args, **kwargs, &block)
      end
    end
    sign_in_with_password
    answer_email
    expect(response).to redirect_to("/users/select")
    expect(events).to be_empty
    post "/users/select", params: { identity_id: user.id }
    expect(response).to redirect_to("/")
    expect(events.size).to eq(1)
    expect(events.sole).to include("purpose" => "sign_in_approval")
  end

  it "requires approval after OAuth authentication as well" do
    account.omni_auth_identities.create!(provider: "github", uid: "approval-user")
    oauth_callback "/users/auth/github/callback",
      auth: OmniAuth::AuthHash.new(provider: "github", uid: "approval-user", info: { email: account.email_address })
    expect(response).to redirect_to("/users/two_factor_challenges")
    answer_email
    expect(response).to redirect_to("/")
  end
end
