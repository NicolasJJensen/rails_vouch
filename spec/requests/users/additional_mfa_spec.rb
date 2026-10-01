require "rails_helper"

RSpec.describe "Additional MFA", type: :request do
  let!(:user) { create(:user) }
  let(:account) { user.account }
  let!(:credential) do
    account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
  end

  before do
    post "/users/sign_in", params: { email_address: account.email_address, password: "password123" }
    expect(response).to redirect_to("/")
  end

  def start_challenge(return_to: "/protected_page")
    get "/users/two_factor_challenges", params: { return_to: return_to }
    expect(response).to have_http_status(:ok)
    get "/users/two_factor_challenges/#{credential.id}"
  end

  %i[show send_code update consume_recovery destroy].each do |action|
    it "does not perform #{action} after the host has denied the action" do
      start_challenge
      codes = account.generate_recovery_codes.value
      original_context = request.session[Vouch::Session.key_for(:user, :two_factor)].deep_dup
      original_attributes = credential.reload.attributes
      Users::TwoFactorChallengeController.define_method(action) do
        head :forbidden
        super()
      end
      expect_any_instance_of(TwoFactorCredential).not_to receive(:challenge)
      expect_any_instance_of(Account).not_to receive(:consume_recovery_code)

      case action
      when :show then get "/users/two_factor_challenges/#{credential.id}"
      when :send_code then post "/users/two_factor_challenges/#{credential.id}/send_code"
      when :update then patch "/users/two_factor_challenges/#{credential.id}", params: { code: "123456" }
      when :consume_recovery
        post "/users/recovery", params: { recovery_owner_type: "Account", recovery_code: codes.first }
      when :destroy then delete "/users/two_factor_challenges"
      end

      expect(response).to have_http_status(:forbidden)
      expect(credential.reload.attributes).to eq(original_attributes)
      expect(account.recovery_codes_remaining).to eq(codes.size)
      expect(request.session[Vouch::Session.key_for(:user, :two_factor)]).to eq(original_context)
    ensure
      Users::TwoFactorChallengeController.remove_method(action) if Users::TwoFactorChallengeController.instance_methods(false).include?(action)
    end
  end

  it "adds proof without rerunning sign-in or changing the signed-in identity" do
    start_challenge
    hooks = []
    allow_any_instance_of(Users::TwoFactorChallengeController).to receive(:run_hooks) do |_controller, hook, *_args|
      hooks << hook
    end
    patch "/users/two_factor_challenges/#{credential.id}", params: { code: ROTP::TOTP.new(credential.otp_secret).now }
    expect(response).to redirect_to("/protected_page")
    expect(hooks).to eq([:two_factor_verification])
    expect(request.session[Vouch::Session.key_for(:user, :evidence)].sole).to include("method" => "two_factor")
    get "/users/two_factor_credentials"
    expect(response).to have_http_status(:ok)
  end

  it "removes obsolete stored proof before starting another challenge" do
    start_challenge
    patch "/users/two_factor_challenges/#{credential.id}", params: { code: ROTP::TOTP.new(credential.otp_secret).now }
    key = Vouch::Session.key_for(:user, :evidence)
    expect(request.session[key]).not_to be_empty
    credential.disable_two_factor!
    credential.enable_two_factor!
    get "/users/two_factor_challenges"
    expect(response).to have_http_status(:ok)
    expect(request.session[key]).to be_nil
  end

  it "keeps the original expiry when the method selector is refreshed" do
    get "/users/two_factor_challenges", params: { return_to: "/protected_page" }
    context = request.session[Vouch::Session.key_for(:user, :two_factor)].deep_dup
    travel 1.minute do
      get "/users/two_factor_challenges", params: { return_to: "/other" }
      expect(request.session[Vouch::Session.key_for(:user, :two_factor)]).to eq(context)
    end
  end

  it "keeps the account signed in after a failed code or cancellation" do
    start_challenge
    patch "/users/two_factor_challenges/#{credential.id}", params: { code: "invalid" }
    expect(response).to have_http_status(:unprocessable_entity)
    delete "/users/two_factor_challenges"
    expect(response).to redirect_to("/protected_page")
    get "/users/two_factor_credentials"
    expect(response).to have_http_status(:ok)
  end

  it "does not return to an external origin" do
    start_challenge(return_to: "https://evil.example/collect")
    delete "/users/two_factor_challenges"
    expect(response).to redirect_to("/")
  end

  it "does not allow an arbitrary credential from another account" do
    other = create(:account).two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    start_challenge
    patch "/users/two_factor_challenges/#{other.id}", params: { code: ROTP::TOTP.new(other.otp_secret).now }
    expect(response).to redirect_to("/users/two_factor_challenges")
    expect(request.session[Vouch::Session.key_for(:user, :evidence)]).to be_nil
  end

  it "refreshes a used credential while keeping proof from another factor" do
    second = account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    [credential, second, credential].each_with_index do |factor, index|
      travel (index + 1) * 31.seconds do
        get "/users/two_factor_challenges"
        get "/users/two_factor_challenges/#{factor.id}"
        patch "/users/two_factor_challenges/#{factor.id}", params: { code: ROTP::TOTP.new(factor.otp_secret).now }
        expect(response).to redirect_to("/")
      end
    end
    proofs = request.session[Vouch::Session.key_for(:user, :evidence)]
    expect(proofs.map { |proof| proof.fetch("credential_id") }).to contain_exactly(credential.id.to_s, second.id.to_s)
  end

  it "keeps recovery proof separate and calls the normal verification hook once" do
    code = account.generate_recovery_codes!.value.first
    get "/users/two_factor_challenges"
    events = []
    allow_any_instance_of(Users::TwoFactorChallengeController).to receive(:run_hooks) do |_controller, hook, *_args|
      events << hook
    end
    post "/users/recovery", params: { recovery_owner_type: "Account", recovery_code: code }
    expect(response).to redirect_to("/")
    expect(events).to eq([:two_factor_verification])
    proof = request.session[Vouch::Session.key_for(:user, :evidence)].sole
    expect(proof).to include("method" => "recovery_code", "owner_type" => "Account")
    expect(proof).not_to have_key("credential_type")
  end

  it "applies a host recovery-owner restriction to submitted account codes" do
    code = account.generate_recovery_codes!.value.first
    get "/users/two_factor_challenges"
    allow_any_instance_of(Users::TwoFactorChallengeController).to receive(:recovery_owners).and_return([])
    post "/users/recovery", params: { recovery_owner_type: "Account", recovery_code: code }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(account.recovery_codes_remaining).to eq(10)
  end

  it "lets a host replace the completion response after the proof is stored" do
    Users::TwoFactorChallengeController.define_method(:update) do
      super() { |result| render json: { status: result.status } }
    end
    start_challenge
    patch "/users/two_factor_challenges/#{credential.id}", params: { code: ROTP::TOTP.new(credential.otp_secret).now }
    expect(response.parsed_body).to eq("status" => "ok")
    expect(request.session[Vouch::Session.key_for(:user, :evidence)].size).to eq(1)
    expect(response.headers["Location"]).to be_nil
  ensure
    Users::TwoFactorChallengeController.remove_method(:update)
  end

  it "expires a pending challenge without ending the existing login" do
    start_challenge
    travel 11.minutes do
      patch "/users/two_factor_challenges/#{credential.id}", params: { code: ROTP::TOTP.new(credential.otp_secret).now }
      expect(response).to redirect_to("/protected_page")
      expect(request.session[Vouch::Session.key_for(:user, :evidence)]).to be_nil
      get "/users/two_factor_credentials"
      expect(response).to have_http_status(:ok)
    end
  end
  [false, true].each do |different_account|
    it "rejects a captured challenge after signing out and signing in #{different_account ? 'another' : 'the same'} account" do
      start_challenge
      captured = request.session[Vouch::Session.key_for(:user, :two_factor)].deep_dup
      delete "/users/sign_out"
      replacement = different_account ? create(:user).account : account
      post "/users/sign_in", params: { email_address: replacement.email_address, password: "password123" }
      expect(response).to redirect_to("/")
      restore = proc { session[Vouch::Session.key_for(:user, :two_factor)] = captured }
      Users::TwoFactorChallengeController.prepend_before_action(restore)
      patch "/users/two_factor_challenges/#{credential.id}", params: { code: ROTP::TOTP.new(credential.otp_secret).now }
      expect(response).to redirect_to("/protected_page")
      expect(request.session[Vouch::Session.key_for(:user, :evidence)]).to be_nil
      expect(credential.reload.two_factor_last_used_at).to be_nil
    ensure
      Users::TwoFactorChallengeController.skip_before_action(restore) if restore
    end
  end

  it "rejects the original challenge after entering and leaving impersonation" do
    start_challenge
    captured = request.session[Vouch::Session.key_for(:user, :two_factor)].deep_dup
    target = create(:user, organisation: user.organisation)
    post "/users/impersonations/#{target.id}"
    expect(response).to redirect_to("/")
    delete "/users/impersonations"
    restore = proc { session[Vouch::Session.key_for(:user, :two_factor)] = captured }
    Users::TwoFactorChallengeController.prepend_before_action(restore)
    patch "/users/two_factor_challenges/#{credential.id}", params: { code: ROTP::TOTP.new(credential.otp_secret).now }
    expect(response).to redirect_to("/protected_page")
    expect(request.session[Vouch::Session.key_for(:user, :evidence)]).to be_nil
    expect(credential.reload.two_factor_last_used_at).to be_nil
  ensure
    Users::TwoFactorChallengeController.skip_before_action(restore) if restore
  end

  it "excludes the exact passwordless credential when asking for another MFA proof later" do
    token = credential.issue_sign_in_code!.token
    code = credential.last_delivered_sign_in_code
    factor_id = credential.id
    Users::SessionsController.define_method(:create) do
      factor = TwoFactorCredential.find(factor_id)
      result = factor.verify_sign_in_code(params[:code], token: params[:token])
      return head :unauthorized unless result.ok?
      outcome = complete_sign_in(factor.account, signed_in_via: factor)
      raise "Passwordless completion failed" unless outcome == :signed_in
      redirect_to "/"
    end
    delete "/users/sign_out"
    post "/users/sign_in", params: { code: code, token: token }
    expect(response).to redirect_to("/")
    expect(request.session[Vouch::Session.key_for(:user, :signed_in_via)]).to include("id" => credential.id.to_s)
    get "/users/two_factor_challenges"
    get "/users/two_factor_challenges/#{credential.id}"
    expect(response).to redirect_to("/users/two_factor_challenges")
    expect(request.session[Vouch::Session.key_for(:user, :evidence)]).to be_nil
    post "/users/recovery_codes", params: { recovery_owner_type: "TwoFactorCredential", recovery_owner_id: credential.id }
    expect(response).to have_http_status(:created)
    expect(credential.recovery_codes_remaining).to eq(10)
  ensure
    Users::SessionsController.remove_method(:create)
  end

  it "reports invalid to the host if a successful adapter disables its credential" do
    Users::TwoFactorChallengeController.define_method(:set_credential) do
      super()
      @credential.define_singleton_method(:verify_challenge) do |*_args, **_options|
        update!(two_factor_enabled_at: nil)
        Vouch::Result.ok
      end
    end
    Users::TwoFactorChallengeController.define_method(:update) do
      super() { |result| render json: { status: result.status } }
    end
    start_challenge
    patch "/users/two_factor_challenges/#{credential.id}", params: { code: "adapter-proof" }
    expect(response.parsed_body).to eq("status" => "invalid")
    expect(request.session[Vouch::Session.key_for(:user, :evidence)]).to be_nil
  ensure
    Users::TwoFactorChallengeController.remove_method(:set_credential)
    Users::TwoFactorChallengeController.remove_method(:update)
  end

end
