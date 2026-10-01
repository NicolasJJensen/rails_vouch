# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Host authentication responses", type: :request do
  let(:account) { create(:account) }
  let!(:identity) { create(:user, account: account) }

  def with_action_response(controller, action, handler)
    controller.define_method(action) do
      super() { |result| instance_exec(result, &handler) }
    end
    yield
  ensure
    controller.remove_method(action)
  end

  def sign_in_request(password: "password123")
    post "/users/sign_in", params: {account: {email_address: account.email_address, password: password}}
  end

  it "lets the host render a successful sign-in response without a second redirect" do
    handler = ->(result) { render json: {status: result.status, account_id: result.value.id} }

    with_action_response(Users::SessionsController, :create, handler) { sign_in_request }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "ok", "account_id" => account.id)
    expect(response.headers["Location"]).to be_nil
  end

  it "lets the host handle invalid credentials" do
    handler = ->(result) { render json: {status: result.status, reason: result.metadata[:reason]}, status: :unprocessable_entity }

    with_action_response(Users::SessionsController, :create, handler) { sign_in_request(password: "incorrect") }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to eq("status" => "invalid", "reason" => "invalid_credentials")
  end

  it "exposes MFA as pending without publishing a signed-in identity" do
    account.two_factor_credentials.create!(verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    handler = ->(result) {
      render json: {status: result.status, next_step: result.metadata[:next_step], signed_in: current_identity.present?}, status: :accepted
    }

    with_action_response(Users::SessionsController, :create, handler) { sign_in_request }

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to eq("status" => "pending", "next_step" => "two_factor", "signed_in" => false)
  end

  it "keeps the default response when the host observes without rendering" do
    observed = []
    handler = ->(result) { observed << result.status }

    with_action_response(Users::SessionsController, :create, handler) { sign_in_request }

    expect(response).to redirect_to("/")
    expect(observed).to eq([:ok])
  end

  it "lets the host replace the sign-out response after the session is cleared" do
    sign_in(identity)
    handler = ->(result) { render json: {status: result.status, signed_in: current_identity.present?} }

    with_action_response(Users::SessionsController, :destroy, handler) { delete "/users/sign_out" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "ok", "signed_in" => false)
  end

  it "reports cancelled sign-out while preserving the authenticated identity" do
    hooks = Users::SessionsController.__hooks
    Users::SessionsController.before_sign_out { throw(:abort) }
    sign_in(identity)
    handler = ->(result) { render json: {status: result.status, signed_in: current_identity.present?} }

    with_action_response(Users::SessionsController, :destroy, handler) { delete "/users/sign_out" }

    expect(response.parsed_body).to eq("status" => "cancelled", "signed_in" => true)
  ensure
    Users::SessionsController.__hooks = hooks if hooks
  end

  it "lets the host handle a completed membership selection" do
    create(:user, account: account)
    sign_in_request
    expect(response).to redirect_to("/users/select")
    handler = ->(result) { render json: {status: result.status, identity_id: current_identity.id} }

    with_action_response(Users::MembershipSessionsController, :create, handler) do
      post "/users/select", params: {identity_id: identity.id}
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "ok", "identity_id" => identity.id)
  end

  it "lets the host handle a rejected membership selection" do
    create(:user, account: account)
    sign_in_request
    handler = ->(result) { render json: {status: result.status}, status: :unprocessable_entity }

    with_action_response(Users::MembershipSessionsController, :create, handler) do
      post "/users/select", params: {identity_id: "missing"}
    end

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to eq("status" => "invalid")
  end
end
