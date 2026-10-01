# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Users::Impersonations", type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_account) do
    create(:account, email_address: "admin@example.com",
           password: "password123", password_confirmation: "password123")
  end
  let!(:admin) { create(:user, account: admin_account, organisation: organisation) }
  let(:target_account) { create(:account) }
  let!(:target_user) { create(:user, account: target_account, organisation: organisation) }

  # Sign in via the real login flow so Warden session state is properly
  # established. The stub-based sign_in helper can't test impersonation
  # because it prevents Warden from storing scoped session data.
  def sign_in_via_login
    post "/users/sign_in", params: { email_address: "admin@example.com", password: "password123" }
  end

  it "prepares the actual target before host action authorization and does not switch after denial" do
    target_id = target_user.id
    Users::ImpersonationsController.define_method(:create) do
      raise "Target was not prepared" unless @identity.id == target_id
      head :forbidden
    end
    sign_in_via_login

    post "/users/impersonations/#{target_user.id}"

    expect(response).to have_http_status(:forbidden)
    expect(request.session[Vouch::ImpersonationStack::SESSION_KEY]).to be_nil
    get "/users/two_factor_credentials"
    expect(response).to have_http_status(:ok)
  ensure
    Users::ImpersonationsController.remove_method(:create)
  end

  it "yields a completed switch for a host response without a second redirect" do
    Users::ImpersonationsController.define_method(:create) do
      super() do |result|
        render json: { status: result.status, identity_id: result.value.id }
      end
    end
    sign_in_via_login

    post "/users/impersonations/#{target_user.id}"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "ok", "identity_id" => target_user.id)
    expect(response.headers["Location"]).to be_nil
  ensure
    Users::ImpersonationsController.remove_method(:create)
  end

  it "yields a cancelled switch without creating impersonation state" do
    hooks = Users::ImpersonationsController.__hooks
    Users::ImpersonationsController.before_impersonation_start { throw :abort }
    Users::ImpersonationsController.define_method(:create) do
      super() { |result| render json: { status: result.status } }
    end
    sign_in_via_login

    post "/users/impersonations/#{target_user.id}"

    expect(response.parsed_body).to eq("status" => "cancelled")
    expect(request.session[Vouch::ImpersonationStack::SESSION_KEY]).to be_nil
  ensure
    Users::ImpersonationsController.remove_method(:create)
    Users::ImpersonationsController.__hooks = hooks if hooks
  end

  %i[destroy destroy_all].each do |action|
    it "yields #{action} after restoring the operator" do
      Users::ImpersonationsController.define_method(action) do
        super() do |result|
          render json: { status: result.status, restored_id: current_identity.id }
        end
      end
      sign_in_via_login
      post "/users/impersonations/#{target_user.id}"

      delete(action == :destroy ? "/users/impersonations" : "/users/impersonations/all")

      expect(response.parsed_body).to eq("status" => "ok", "restored_id" => admin.id)
      expect(response.headers["Location"]).to be_nil
    ensure
      Users::ImpersonationsController.remove_method(action)
    end
  end

  describe "POST /users/impersonations/:id" do
    it "requires authentication" do
      post "/users/impersonations/#{target_user.id}"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "starts impersonation and redirects to root" do
      sign_in_via_login
      post "/users/impersonations/#{target_user.id}"
      expect(response).to redirect_to("/")
    end

  end

  describe "DELETE /users/impersonations" do
    it "requires authentication" do
      delete "/users/impersonations"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "restores the original user after ending impersonation" do
      sign_in_via_login
      post "/users/impersonations/#{target_user.id}"

      delete "/users/impersonations"
      expect(response).to redirect_to("/")

      # Confirm we're still authenticated — a protected endpoint returns 200
      get "/users/two_factor_credentials"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "DELETE /users/impersonations/all" do
    it "requires authentication" do
      delete "/users/impersonations/all"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "restores the original user after ending all impersonations" do
      sign_in_via_login
      post "/users/impersonations/#{target_user.id}"

      delete "/users/impersonations/all"
      expect(response).to redirect_to("/")

      # Confirm we're still authenticated — a protected endpoint returns 200
      get "/users/two_factor_credentials"
      expect(response).to have_http_status(:ok)
    end
  end
  it "keeps recovery-code management on the operator in a combined account and identity scope" do
    original_codes = admin_account.generate_recovery_codes!.value
    target_codes = target_account.generate_recovery_codes!.value
    sign_in_via_login
    post "/users/impersonations/#{target_user.id}"
    post "/users/recovery_codes", params: {recovery_owner_type: "account"}
    expect(response).to have_http_status(:created)
    expect(admin_account.consume_recovery_code!(original_codes.first)).not_to be_ok
    expect(target_account.consume_recovery_code!(target_codes.first)).to be_ok
  end

end
