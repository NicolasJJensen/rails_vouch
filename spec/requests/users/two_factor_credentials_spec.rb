# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Users::TwoFactorCredentials", type: :request do
  let(:organisation) { create(:organisation) }
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, organisation: organisation) }

  it "prepares a new credential before authorization and does not save after a denied action" do
    Users::TwoFactorCredentialsController.define_method(:create) do
      raise "missing credential" unless @credential&.new_record?
      head :forbidden
      super()
    end
    sign_in(user)
    expect {
      post "/users/two_factor_credentials", params: { two_factor_credential: { type: "email" } }
    }.not_to change(TwoFactorCredential, :count)
    expect(response).to have_http_status(:forbidden)
  ensure
    Users::TwoFactorCredentialsController.remove_method(:create)
  end

  it "prepares an owned credential before authorization and does not delete after a denied action" do
    credential = account.two_factor_credentials.create!(otp_secret: SecureRandom.hex(20))
    Users::TwoFactorCredentialsController.define_method(:destroy) do
      raise "missing credential" unless @credential&.persisted?
      head :forbidden
      super()
    end
    sign_in(user)
    expect { delete "/users/two_factor_credentials/#{credential.id}" }.not_to change(TwoFactorCredential, :count)
    expect(response).to have_http_status(:forbidden)
  ensure
    Users::TwoFactorCredentialsController.remove_method(:destroy)
  end

  it "lets the host replace a successful creation response" do
    Users::TwoFactorCredentialsController.define_method(:create) do
      status = super()
      render json: { id: @credential.id }, status: :created if status == :ok
    end
    sign_in(user)
    post "/users/two_factor_credentials", params: { two_factor_credential: { type: "email" } }
    expect(response).to have_http_status(:created)
    expect(account.two_factor_credentials.find(response.parsed_body.fetch("id"))).to be_present
  ensure
    Users::TwoFactorCredentialsController.remove_method(:create)
  end

  it "keeps the default response when the host observes the status without responding" do
    Users::TwoFactorCredentialsController.define_method(:create) do
      status = super()
      response.set_header("X-Operation-Status", status.to_s)
    end
    sign_in(user)

    post "/users/two_factor_credentials", params: { two_factor_credential: { type: "email" } }

    expect(response).to redirect_to("/users/two_factor_credentials")
    expect(response.headers["X-Operation-Status"]).to eq("ok")
  ensure
    Users::TwoFactorCredentialsController.remove_method(:create)
  end

  it "lets the host handle validation errors on the credential after super" do
    callback = proc { errors.add(:base, "Credential registration is unavailable") }
    TwoFactorCredential.validate(callback)
    Users::TwoFactorCredentialsController.define_method(:create) do
      status = super()
      render json: { status: status, errors: @credential.errors.full_messages }, status: :unprocessable_entity
    end
    sign_in(user)

    expect do
      post "/users/two_factor_credentials", params: { two_factor_credential: { type: "email" } }
    end.not_to change(TwoFactorCredential, :count)

    expect(response.parsed_body).to eq("status" => "invalid", "errors" => ["Credential registration is unavailable"])
    expect(response.headers["Location"]).to be_nil
  ensure
    TwoFactorCredential.skip_callback(:validate, :before, callback) if callback
    Users::TwoFactorCredentialsController.remove_method(:create)
  end

  describe "GET /users/two_factor_credentials" do
    it "requires authentication" do
      get "/users/two_factor_credentials"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "lists credentials when authenticated" do
      sign_in(user)
      get "/users/two_factor_credentials"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /users/two_factor_credentials/new" do
    it "requires authentication" do
      get "/users/two_factor_credentials/new"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "renders the new form when authenticated" do
      sign_in(user)
      get "/users/two_factor_credentials/new"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /users/two_factor_credentials" do
    it "requires authentication" do
      post "/users/two_factor_credentials", params: {
        two_factor_credential: { enabled: true }
      }
      expect(response).to redirect_to("/users/sign_in")
    end

    it "creates a credential when authenticated" do
      sign_in(user)

      expect {
        post "/users/two_factor_credentials", params: {
          two_factor_credential: { enabled: true }
        }
      }.to change(TwoFactorCredential, :count).by(1)

      expect(response).to redirect_to("/users/two_factor_credentials")
    end
  end

  describe "DELETE /users/two_factor_credentials/:id" do
    it "requires authentication" do
      credential = account.two_factor_credentials.create!(otp_secret: SecureRandom.hex(20), enabled: true)
      delete "/users/two_factor_credentials/#{credential.id}"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "deletes the credential when authenticated" do
      sign_in(user)
      credential = account.two_factor_credentials.create!(otp_secret: SecureRandom.hex(20), enabled: true)

      expect {
        delete "/users/two_factor_credentials/#{credential.id}"
      }.to change(TwoFactorCredential, :count).by(-1)

      expect(response).to redirect_to("/users/two_factor_credentials")
    end

    it "redirects with alert for non-existent credential" do
      sign_in(user)
      delete "/users/two_factor_credentials/999999"
      expect(response).to redirect_to("/users/two_factor_credentials")
      expect(flash[:alert]).to eq("2FA method not found.")
    end
  end
end
