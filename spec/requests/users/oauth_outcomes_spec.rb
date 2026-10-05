require "rails_helper"

RSpec.describe "OAuth action outcomes", type: :request do
  around do |example|
    mapping = Vouch.mapping_for(:user)
    registration = mapping.oauth_registration
    hooks = Users::OmniAuthsController.__hooks
    example.run
  ensure
    mapping.oauth_registration = registration
    Users::OmniAuthsController.__hooks = hooks
    %i[callback failure].each do |action|
      Users::OmniAuthsController.remove_method(action) if Users::OmniAuthsController.instance_methods(false).include?(action)
    end
  end

  def observe(action = :callback, &handler)
    outcomes = []
    Users::OmniAuthsController.define_method(action) do
      status = super(&nil)
      outcome = {status: status, account: @account, operation: @operation, next_step: @next_step,
        committed: @registration_committed, reason: @failure_reason, error: @operation_error}
      outcomes << outcome
      if handler
        handler.call(self, outcome)
      else
        render json: outcome.except(:account, :error)
      end
    end
    outcomes
  end

  def provider(uid = "outcome")
    OmniAuth::AuthHash.new(provider: "github", uid: uid, info: {email: "#{uid}@example.test"})
  end

  def linked_user
    create(:user).tap { |user| user.account.omni_auth_identities.create!(provider: "github", uid: "outcome", auth_data: "{}") }
  end

  it "returns successful sign-in once and suppresses the default redirect" do
    user = linked_user
    outcomes = observe
    oauth_callback "/users/auth/github/callback", auth: provider
    expect(outcomes.size).to eq(1)
    expect(outcomes.first[:status]).to eq(:ok)
    expect(outcomes.first[:account]).to eq(user.account)
    expect(response.headers["Location"]).to be_nil
  end

  it "returns a form continuation without saving an account" do
    Vouch.mapping_for(:user).oauth_registration = :form
    outcomes = observe
    expect { oauth_callback "/users/auth/github/callback", auth: provider, purpose: :register }.not_to change(Account, :count)
    expect(outcomes.first[:status]).to eq(:pending)
    expect(outcomes.first[:next_step]).to eq(:registration)
  end

  it "lets the host choose form or automatic registration from the prepared account" do
    Users::OmniAuthsController.define_method(:oauth_registration_required?) { !@account.valid? }
    outcomes = observe
    incomplete = OmniAuth::AuthHash.new(provider: "github", uid: "without-email", info: {})
    expect { oauth_callback "/users/auth/github/callback", auth: incomplete, purpose: :register }.not_to change(Account, :count)
    expect(outcomes.last[:status]).to eq(:pending)
    expect(outcomes.last[:next_step]).to eq(:registration)
    expect { oauth_callback "/users/auth/github/callback", auth: provider, purpose: :register }.to change(Account, :count).by(1)
    expect(outcomes.last[:status]).to eq(:ok)
  ensure
    Users::OmniAuthsController.remove_method(:oauth_registration_required?)
  end

  it "returns automatic registration success after the records commit" do
    outcomes = observe
    expect { oauth_callback "/users/auth/github/callback", auth: provider, purpose: :register }.to change(Account, :count).by(1)
    expect(outcomes.first[:status]).to eq(:ok)
    expect(outcomes.first).to include(operation: :registration, committed: true)
  end

  it "retains a committed registration when later authentication fails" do
    allow_any_instance_of(Users::OmniAuthsController).to receive(:complete_sign_in).and_return(:no_identity)
    outcomes = observe
    expect { oauth_callback "/users/auth/github/callback", auth: provider, purpose: :register }.to change(Account, :count).by(1)
    expect(outcomes.first[:status]).to eq(:invalid)
    expect(outcomes.first[:committed]).to be true
  end

  it "returns required MFA and selection as distinct pending steps" do
    user = linked_user
    create(:user, account: user.account)
    outcomes = observe
    oauth_callback "/users/auth/github/callback", auth: provider
    expect(outcomes.last[:next_step]).to eq(:selection)
    factor = user.account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    user.account.enable_two_factor!
    oauth_callback "/users/auth/github/callback", auth: provider
    expect(outcomes.last[:status]).to eq(:pending)
    expect(outcomes.last[:next_step]).to eq(:two_factor)
  end

  it "returns linking success and a conflicting provider as outcomes" do
    user = create(:user)
    sign_in(user)
    outcomes = observe
    oauth_callback "/users/auth/github/callback", auth: provider, purpose: :link
    expect(outcomes.last[:status]).to eq(:ok)
    expect(outcomes.last[:operation]).to eq(:link)
    other = create(:account)
    other.omni_auth_identities.create!(provider: "github", uid: "elsewhere", auth_data: "{}")
    oauth_callback "/users/auth/github/callback", auth: provider("elsewhere"), purpose: :link
    expect(outcomes.last[:status]).to eq(:invalid)
    expect(outcomes.last[:reason]).to eq(:already_linked)
  end

  it "returns a cancelled linking operation without the default forbidden response" do
    sign_in(create(:user))
    Users::OmniAuthsController.before_oauth_link { throw :abort }
    outcomes = observe
    oauth_callback "/users/auth/github/callback", auth: provider, purpose: :link
    expect(outcomes.first[:status]).to eq(:cancelled)
    expect(response).to have_http_status(:ok)
  end

  it "returns validation errors with the original exception" do
    outcomes = observe
    auth = provider
    auth.info.email = nil
    oauth_callback "/users/auth/github/callback", auth: auth, purpose: :register
    expect(outcomes.first[:status]).to eq(:invalid)
    expect(outcomes.first[:error]).to be_a(ActiveRecord::RecordInvalid)
    expect(outcomes.first[:committed]).to be false
  end

  it "returns malformed callbacks and provider failure actions" do
    outcomes = observe
    get "/users/auth/github/callback"
    expect(outcomes.first[:reason]).to eq(:failed)
    failures = observe(:failure)
    get "/users/auth/failure"
    expect(failures.first[:status]).to eq(:invalid)
    expect(response).to have_http_status(:ok)
  end

  it "leaves host response exceptions to Rails instead of handling them as registration failures" do
    outcomes = observe { |_controller, _result| raise ActiveRecord::RecordInvalid }
    expect_any_instance_of(Users::OmniAuthsController).not_to receive(:oauth_registration_failed)
    oauth_callback "/users/auth/github/callback", auth: provider, purpose: :register
    expect(outcomes.first[:status]).to eq(:ok)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.headers["Location"]).to be_nil
  end
end
