require "rails_helper"
require "omniauth"

RSpec.describe "OAuth request purposes", type: :request do
  let(:auth) { OmniAuth::AuthHash.new(provider: "example", uid: "provider-user", info: { email: "provider@example.test" }) }

  def start_oauth(purpose)
    post "/users/auth/example", params: { purpose: purpose }
    response.parsed_body
  end

  def finish_oauth(request_params, params: {})
    get "/users/auth/example/callback", params: params,
      env: { "omniauth.auth" => auth, "omniauth.params" => request_params }
  end

  it "does not register an unknown provider during sign-in" do
    request_params = start_oauth(:sign_in)
    expect { finish_oauth(request_params) }.not_to change(Account, :count)
    expect(response).to redirect_to("/users/sign_in")
    expect(flash[:alert]).to include("Register to use it")
  end

  it "defaults an initiation without purpose to sign-in" do
    post "/users/auth/example"
    request_params = response.parsed_body
    expect { finish_oauth(request_params) }.not_to change(Account, :count)
    expect(flash[:alert]).to include("Register to use it")
  end

  it "does not sign in an already linked provider during registration" do
    account = create(:account)
    create(:user, account: account)
    account.omni_auth_identities.create!(provider: auth.provider, uid: auth.uid)

    finish_oauth(start_oauth(:register), params: { purpose: "sign_in" })

    expect(response).to redirect_to("/users/sign_up")
    expect(flash[:alert]).to include("already connected")
    expect(controller.send(:current_identity)).to be_nil
  end

  it "rejects linking after another account becomes current" do
    sign_in(create(:user))
    request_params = start_oauth(:link)
    sign_in(create(:user))

    expect { finish_oauth(request_params) }.not_to change(OmniAuthIdentity, :count)
    expect(flash[:alert]).to include("session changed")
  end

  it "rejects linking after signing out and back into the same account" do
    user = create(:user)
    sign_in(user)
    request_params = start_oauth(:link)
    delete "/users/sign_out"
    post "/users/sign_in", params: { account: { email_address: user.email_address, password: "password123" } }

    expect { finish_oauth(request_params) }.not_to change(OmniAuthIdentity, :count)
    expect(flash[:alert]).to include("session changed")
  end

  it "does not turn an in-flight registration into account linking" do
    request_params = start_oauth(:register)
    sign_in(create(:user))

    expect { finish_oauth(request_params) }.not_to change(OmniAuthIdentity, :count)
    expect(flash[:alert]).to include("session changed")
  end

  it "requires the request association supplied by OmniAuth" do
    request_params = start_oauth(:register)
    expect do
      get "/users/auth/example/callback", params: request_params,
        env: { "omniauth.auth" => auth }
    end.not_to change(Account, :count)
    expect(flash[:alert]).to include("Restart")
  end

  it "consumes a linking request once" do
    sign_in(create(:user))
    request_params = start_oauth(:link)
    expect { finish_oauth(request_params) }.to change(OmniAuthIdentity, :count).by(1)

    expect { finish_oauth(request_params) }.not_to change(OmniAuthIdentity, :count)
    expect(flash[:alert]).to include("Restart")
  end

  it "lets the host replace a context-changed response" do
    Users::OmniAuthsController.define_method(:callback) do
      super()
      render json: { reason: @failure_reason }, status: :conflict
    end
    request_params = start_oauth(:register)
    sign_in(create(:user))

    finish_oauth(request_params)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq("reason" => "context_changed")
  ensure
    Users::OmniAuthsController.remove_method(:callback)
  end
end
