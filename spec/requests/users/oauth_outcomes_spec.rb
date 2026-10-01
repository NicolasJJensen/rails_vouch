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
      super() do |result|
        outcomes << result
        if handler
          handler.call(self, result)
        else
          render json: {status: result.status, operation: result.metadata[:operation], next_step: result.metadata[:next_step]}
        end
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

  it "yields successful sign-in once and suppresses the default redirect" do
    user = linked_user
    outcomes = observe
    oauth_callback "/users/auth/github/callback", auth: provider
    expect(outcomes.size).to eq(1)
    expect(outcomes.first).to be_ok
    expect(outcomes.first.value).to eq(user.account)
    expect(response.headers["Location"]).to be_nil
  end

  it "yields a form continuation without saving an account" do
    Vouch.mapping_for(:user).oauth_registration = :form
    outcomes = observe
    expect { oauth_callback "/users/auth/github/callback", auth: provider, purpose: :register }.not_to change(Account, :count)
    expect(outcomes.first).to be_pending
    expect(outcomes.first.metadata[:next_step]).to eq(:registration)
  end

  it "yields automatic registration success after the records commit" do
    outcomes = observe
    expect { oauth_callback "/users/auth/github/callback", auth: provider, purpose: :register }.to change(Account, :count).by(1)
    expect(outcomes.first).to be_ok
    expect(outcomes.first.metadata).to include(operation: :registration, committed: true)
  end

  it "retains a committed registration when later authentication fails" do
    allow_any_instance_of(Users::OmniAuthsController).to receive(:complete_sign_in).and_return(:no_identity)
    outcomes = observe
    expect { oauth_callback "/users/auth/github/callback", auth: provider, purpose: :register }.to change(Account, :count).by(1)
    expect(outcomes.first).to be_invalid
    expect(outcomes.first.metadata[:committed]).to be true
  end

  it "yields required MFA and selection as distinct pending steps" do
    user = linked_user
    create(:user, account: user.account)
    outcomes = observe
    oauth_callback "/users/auth/github/callback", auth: provider
    expect(outcomes.last.metadata[:next_step]).to eq(:selection)
    factor = user.account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    user.account.enable_two_factor!
    oauth_callback "/users/auth/github/callback", auth: provider
    expect(outcomes.last).to be_pending
    expect(outcomes.last.metadata[:next_step]).to eq(:two_factor)
  end

  it "yields linking success and a conflicting provider as outcomes" do
    user = create(:user)
    sign_in(user)
    outcomes = observe
    oauth_callback "/users/auth/github/callback", auth: provider, purpose: :link
    expect(outcomes.last).to be_ok
    expect(outcomes.last.metadata[:operation]).to eq(:link)
    other = create(:account)
    other.omni_auth_identities.create!(provider: "github", uid: "elsewhere", auth_data: "{}")
    oauth_callback "/users/auth/github/callback", auth: provider("elsewhere"), purpose: :link
    expect(outcomes.last).to be_invalid
    expect(outcomes.last.metadata[:reason]).to eq(:already_linked)
  end

  it "yields a cancelled linking operation without the default forbidden response" do
    sign_in(create(:user))
    Users::OmniAuthsController.before_oauth_link { throw :abort }
    outcomes = observe
    oauth_callback "/users/auth/github/callback", auth: provider, purpose: :link
    expect(outcomes.first).to be_cancelled
    expect(response).to have_http_status(:ok)
  end

  it "yields validation errors with the original exception" do
    outcomes = observe
    auth = provider
    auth.info.email = nil
    oauth_callback "/users/auth/github/callback", auth: auth, purpose: :register
    expect(outcomes.first).to be_invalid
    expect(outcomes.first.error).to be_a(ActiveRecord::RecordInvalid)
    expect(outcomes.first.metadata[:committed]).to be false
  end

  it "yields malformed callbacks and provider failure actions" do
    outcomes = observe
    get "/users/auth/github/callback"
    expect(outcomes.first.metadata[:reason]).to eq(:failed)
    failures = observe(:failure)
    get "/users/auth/failure"
    expect(failures.first).to be_invalid
    expect(response).to have_http_status(:ok)
  end

  it "leaves host response exceptions to Rails instead of handling them as registration failures" do
    outcomes = observe { |_controller, _result| raise ActiveRecord::RecordInvalid }
    expect_any_instance_of(Users::OmniAuthsController).not_to receive(:oauth_registration_failed)
    oauth_callback "/users/auth/github/callback", auth: provider, purpose: :register
    expect(outcomes.first).to be_ok
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.headers["Location"]).to be_nil
  end
end
