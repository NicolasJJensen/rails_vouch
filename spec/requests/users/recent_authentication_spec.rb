require "rails_helper"

RSpec.describe "Recent authentication", type: :request do
  let!(:user) { create(:user) }
  let(:account) { user.account }

  before do
    @previous_callbacks = Users::RecoveryCodesController._process_action_callbacks.to_a
    Users::RecoveryCodesController.require_recent_authentication(scope: :user, within: 1.minute)
    post "/users/sign_in", params: { email_address: account.email_address, password: "password123" }
  end

  after do
    (Users::RecoveryCodesController._process_action_callbacks.to_a - @previous_callbacks).each do |callback|
      Users::RecoveryCodesController.skip_callback(:process_action, callback.kind, callback.filter)
    end
  end

  it "accepts a recent password sign-in without creating MFA evidence" do
    get "/users/recovery_codes"
    expect(response).to have_http_status(:ok)
    expect(request.session[Vouch::Session.key_for(:user, :evidence)]).to be_nil
  end

  it "accepts fresh OAuth sign-in and later lets a passwordless account confirm with recovery" do
    delete "/users/sign_out"
    oauth_owner = Account.find(account.id)
    oauth_owner.update!(password_digest: nil)
    OmniAuthIdentity.create!(account: account, provider: "google_oauth2", uid: "confirmation-oauth")
    oauth_callback "/users/auth/google_oauth2/callback", purpose: :sign_in,
      auth: OmniAuth::AuthHash.new(provider: "google_oauth2", uid: "confirmation-oauth", info: { email: account.email_address })
    get "/users/recovery_codes"
    expect(response).to have_http_status(:ok)
    codes = oauth_owner.generate_recovery_codes.value
    travel 2.minutes do
      get "/users/recovery_codes"
      follow_redirect!
      expect(response.body).not_to include('type="password"')
      expect(response.body).to include("Use an authenticator or recovery code")
      get "/users/two_factor_challenges", params: { return_to: "/users/recovery_codes" }
      post "/users/recovery", params: { recovery_owner_type: "Account", recovery_code: codes.first }
      follow_redirect!
      expect(response).to have_http_status(:ok)
    end
  end

  it "confirms the password without replaying a modifying request or firing sign-in hooks" do
    travel 2.minutes do
      post "/users/recovery_codes", headers: { "HTTP_REFERER" => "http://www.example.com/users/recovery_codes" }
      expect(response).to redirect_to("/users/confirmation?confirmation_scope=user")
      expect(account.recovery_codes_remaining).to eq(0)
      follow_redirect!
      expect(response.body).to include("Your password")
      hooks = []
      allow_any_instance_of(Users::SessionsController).to receive(:run_hooks).and_wrap_original do |original, kind, *args, **options, &block|
        hooks << kind
        original.call(kind, *args, **options, &block)
      end
      post "/users/confirmation", params: { password: "password123", confirmation_scope: :user }
      expect(response).to redirect_to("/users/recovery_codes")
      expect(account.recovery_codes_remaining).to eq(0)
      expect(hooks).to include(:authentication_confirmation, :commit_of_authentication_confirmation)
      expect(hooks).not_to include(:sign_in, :commit_of_sign_in)
      follow_redirect!
      expect(response).to have_http_status(:ok)
      expect(request.session[Vouch::Session.key_for(:user, :evidence)]).to be_nil
    end
  end

  it "does not publish confirmation when a normal lifecycle callback cancels it" do
    original_hooks = Users::SessionsController.__hooks
    Users::SessionsController.before_authentication_confirmation { throw :abort }
    travel 2.minutes do
      get "/users/recovery_codes"
      confirmation = request.session[Vouch::Session.key_for(:user, :confirmation)].deep_dup
      post "/users/confirmation", params: { password: "password123" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(request.session[Vouch::Session.key_for(:user, :confirmation)]).to eq(confirmation)
      get "/users/recovery_codes"
      expect(response).to redirect_to("/users/confirmation?confirmation_scope=user")
    end
  ensure
    Users::SessionsController.__hooks = original_hooks if original_hooks
  end

  it "does not recursively guard the native confirmation endpoint" do
    previous = Users::SessionsController._process_action_callbacks.to_a
    Users::SessionsController.require_recent_authentication(scope: :user, within: 1.minute, only: %i[confirmation confirm])
    travel 2.minutes do
      get "/users/recovery_codes"
      follow_redirect!
      expect(response).to have_http_status(:ok)
      post "/users/confirmation", params: { password: "password123" }
      expect(response).to redirect_to("/users/recovery_codes")
    end
  ensure
    (Users::SessionsController._process_action_callbacks.to_a - previous).each do |callback|
      Users::SessionsController.skip_callback(:process_action, callback.kind, callback.filter)
    end
  end

  it "counts incorrect password attempts and retains the existing signed-in account" do
    travel 2.minutes do
      get "/users/recovery_codes"
      post "/users/confirmation", params: { password: "incorrect", confirmation_scope: :user }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(account.reload.failed_attempts).to eq(1)
      expect(request.env.fetch("warden").user(:user)).to eq(user)
    end
  end

  it "expires pending confirmation and does not extend it when refreshed" do
    travel 2.minutes do
      get "/users/recovery_codes"
      key = Vouch::Session.key_for(:user, :confirmation_pending)
      pending = request.session[key].deep_dup
      follow_redirect!
      expect(request.session[key]).to eq(pending)
      travel Vouch.configuration.pending_authentication_ttl + 1.second
        post "/users/confirmation", params: { password: "password123" }
        expect(response).to redirect_to("/")
        expect(flash[:alert]).to eq("Confirmation expired. Please try the action again.")
        expect(request.session[key]).to be_nil
    end
  end

  it "cancels confirmation and rejects external return destinations" do
    get "/users/confirmation", params: { return_to: "https://evil.test/steal" }
    delete "/users/confirmation"
    expect(response).to redirect_to("/")
    expect(request.session[Vouch::Session.key_for(:user, :confirmation_pending)]).to be_nil
    expect(request.env.fetch("warden").user(:user)).to eq(user)
  end

  [false, true].each do |different_account|
    it "rejects a pending confirmation captured before signing in #{different_account ? 'another' : 'the same'} account" do
      get "/users/confirmation"
      captured = request.session[Vouch::Session.key_for(:user, :confirmation_pending)].deep_dup
      delete "/users/sign_out"
      replacement = different_account ? create(:user).account : account
      post "/users/sign_in", params: { email_address: replacement.email_address, password: "password123" }
      restore = proc { session[Vouch::Session.key_for(:user, :confirmation_pending)] = captured }
      Users::SessionsController.prepend_before_action(restore)
      post "/users/confirmation", params: { password: "password123" }
      expect(response).to redirect_to("/")
      expect(flash[:alert]).to eq("Confirmation expired. Please try the action again.")
    ensure
      Users::SessionsController.skip_before_action(restore) if restore
    end
  end

  it "confirms the original operator rather than the impersonated membership's account" do
    target = create(:user, organisation: user.organisation)
    target.account.update!(password: "target-password", password_confirmation: "target-password")
    post "/users/impersonations/#{target.id}"
    get "/users/recovery_codes"
    expect(response).to redirect_to("/users/confirmation?confirmation_scope=user")
    follow_redirect!
    expect(response.body).not_to include("Use an authenticator or recovery code")
    post "/users/confirmation", params: { password: "target-password" }
    expect(response).to have_http_status(:unprocessable_entity)
    post "/users/confirmation", params: { password: "password123" }
    expect(response).to redirect_to("/users/recovery_codes")
    expect(request.env.fetch("warden").user(:user)).to eq(target)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(request.session[Vouch::Session.key_for(:user, :evidence)]).to be_nil
  end

  it "accepts fresh recovery proof without requesting the lost factor again" do
    codes = account.generate_recovery_codes.value
    travel 2.minutes do
      get "/users/recovery_codes"
      follow_redirect!
      expect(response.body).to include("Use an authenticator or recovery code")
      get "/users/two_factor_challenges", params: { return_to: "/users/recovery_codes" }
      post "/users/recovery", params: { recovery_owner_type: "Account", recovery_code: codes.first }
      expect(response).to redirect_to("/users/recovery_codes")
      follow_redirect!
      expect(response).to have_http_status(:ok)
      expect(account.recovery_codes_remaining).to eq(codes.size - 1)
    end
  end

  it "does not sign out after the host has already denied the action" do
    %i[create destroy].each do |action|
      Users::SessionsController.define_method(action) { head :forbidden; super() }
    end
    current_session = request.session.to_hash.except("session_id").deep_dup
    delete "/users/sign_out"
    expect(response).to have_http_status(:forbidden)
    expect(request.env.fetch("warden").user(:user)).to eq(user)
    expect(request.session.to_hash.except("session_id")).to eq(current_session)
  ensure
    %i[create destroy].each { |action| Users::SessionsController.remove_method(action) }
  end
  it "does not sign in after the host has already denied the action" do
    delete "/users/sign_out"
    Users::SessionsController.define_method(:create) { head :forbidden; super() }
    post "/users/sign_in", params: { email_address: account.email_address, password: "password123" }
    expect(response).to have_http_status(:forbidden)
    expect(request.env.fetch("warden").user(:user)).to be_nil
    expect(request.session[Vouch::Session.key_for(:user, :confirmation)]).to be_nil
  ensure
    Users::SessionsController.remove_method(:create)
  end

end
