require "rails_helper"

RSpec.describe "Host passwordless sign-in", type: :request do
  let(:user) { create(:user) }
  let(:account) { user.account }
  let(:phone) { account.two_factor_credentials.create!(verified_at: Time.current, type: "phone") }

  before do
    allow_any_instance_of(TwoFactorCredential).to receive(:deliver_sign_in_code) { |_record, code| @code = code }
  end

  def start
    post "/phone_sign_in", params: { credential_id: phone.id }
    expect(response).to redirect_to("/phone_sign_in")
    get "/phone_sign_in"
    expect(response.body).to include("Enter the code")
  end

  it "issues, verifies, completes sign-in and retains only the first-factor reference" do
    start
    patch "/phone_sign_in", params: { code: @code }

    expect(response).to redirect_to("/")
    expect(request.env["warden"].user(:user)).to eq(user)
    expect(request.session[:phone_sign_in]).to be_nil
    expect(request.session[Vouch::Session.key_for(:user, :signed_in_via)]).to include("id" => phone.id.to_s)
    expect(request.session[Vouch::Session.key_for(:user, :evidence)]).to be_nil
  end

  it "keeps an invalid proof retryable, then rejects replay after successful sign-in" do
    start
    patch "/phone_sign_in", params: { code: "wrong" }
    expect(response.parsed_body["status"]).to eq("invalid")
    expect(request.env["warden"].user(:user)).to be_nil

    patch "/phone_sign_in", params: { code: @code }
    expect(response).to redirect_to("/")
    delete "/users/sign_out"
    patch "/phone_sign_in", params: { code: @code }
    expect(response).to redirect_to("/phone_sign_in/new")
  end

  it "rejects expiry without creating a session" do
    start
    travel(Vouch.configuration.magic_linkable.validity + 1.second) do
      patch "/phone_sign_in", params: { code: @code }
      expect(response.parsed_body["status"]).to eq("invalid")
      expect(request.env["warden"].user(:user)).to be_nil
    end
  end

  it "continues through membership selection when several identities belong to the account" do
    create(:user, account: account)
    start
    patch "/phone_sign_in", params: { code: @code }

    expect(response).to redirect_to("/users/select")
    expect(request.env["warden"].user(:user)).to be_nil
  end

  it "continues through required MFA without offering the primary credential" do
    phone.update!(two_factor_enabled_at: Time.current)
    account.two_factor_credentials.create!(verified_at: Time.current, two_factor_enabled_at: Time.current, type: "email")
    account.enable_two_factor!
    start
    patch "/phone_sign_in", params: { code: @code }

    expect(response).to redirect_to("/users/two_factor_challenges")
    expect(request.env["warden"].user(:user)).to be_nil
    get "/users/two_factor_challenges/#{phone.id}"
    expect(response).to redirect_to("/users/two_factor_challenges")
  end

  it "does not establish a membership when the owner has none" do
    phone
    user.destroy!
    start
    patch "/phone_sign_in", params: { code: @code }

    expect(response).to redirect_to("/phone_sign_in/new")
    expect(request.env["warden"].user(:user)).to be_nil
  end

  it "does not bypass required MFA when the primary credential is the only factor" do
    phone.update!(two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    Users::TwoFactorChallengeController.define_method(:index) do
      super()
      render json: { eligible: @credentials.size, missing: @enrollment_required }
    end
    start
    patch "/phone_sign_in", params: { code: @code }
    get "/users/two_factor_challenges"

    expect(response.parsed_body).to include("eligible" => 0, "missing" => true)
    expect(request.env["warden"].user(:user)).to be_nil
  ensure
    Users::TwoFactorChallengeController.remove_method(:index)
  end

  it "retains a code when consumption is cancelled by a callback" do
    start
    callback = -> { throw(:abort) }
    TwoFactorCredential.before_update(callback)
    patch "/phone_sign_in", params: { code: @code }
    expect(response.parsed_body["status"]).to eq("cancelled")
    expect(request.env["warden"].user(:user)).to be_nil
    TwoFactorCredential.skip_callback(:update, :before, callback)
    callback = nil

    patch "/phone_sign_in", params: { code: @code }
    expect(response).to redirect_to("/")
  ensure
    TwoFactorCredential.skip_callback(:update, :before, callback) if callback
  end

  it "clears the continuation after the credential locks" do
    start
    Vouch.configuration.magic_linkable.max_attempts.times { patch "/phone_sign_in", params: { code: "wrong" } }
    patch "/phone_sign_in", params: { code: @code }

    expect(response.parsed_body["status"]).to eq("locked")
    expect(request.session[:phone_sign_in]).to be_nil
    expect(request.env["warden"].user(:user)).to be_nil
  end

  it "reports delivery failure without retaining a usable continuation" do
    allow_any_instance_of(TwoFactorCredential).to receive(:deliver_sign_in_code).and_raise(Users::PhoneSessionsController::DeliveryError)
    post "/phone_sign_in", params: { credential_id: phone.id }

    expect(response).to have_http_status(:service_unavailable)
    expect(request.session[:phone_sign_in]).to be_nil
  end
end
