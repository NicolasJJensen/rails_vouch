# frozen_string_literal: true

require "rails_helper"
require "omniauth"

RSpec.describe "Users lifecycle hook phases", type: :request do
  before do
    # Transactional fixtures intentionally roll their outer transaction back.
    # Exercise controller ordering here; the hook helper's own unit contract
    # verifies that production callbacks wait for an actual commit.
    allow(ActiveRecord).to receive(:after_all_transactions_commit).and_yield
  end

  def preserve_hooks(controller, hook)
    original = controller.__hooks
    yield
  ensure
    controller.__hooks = original if original
  end

  it "runs sign-up after hooks after persistence and identity publication" do
    observed = []
    preserve_hooks(Users::RegistrationsController, :sign_up) do
      Users::RegistrationsController.after_sign_up do |account, identity|
        observed << [account.persisted?, current_identity == identity]
      end

      post "/users/sign_up", params: {account: {
        email_address: "phased-sign-up@example.com", password: "password123", password_confirmation: "password123"
      }}
    end

    expect(observed).to eq([[true, true]])
  end

  it "does not run sign-up after hooks when a before hook halts the operation" do
    after_calls = 0
    preserve_hooks(Users::RegistrationsController, :sign_up) do
      Users::RegistrationsController.before_sign_up { throw(:abort) }
      Users::RegistrationsController.after_sign_up { after_calls += 1 }

      post "/users/sign_up", params: {account: {
        email_address: "halted-sign-up@example.com", password: "password123", password_confirmation: "password123"
      }}
    end

    expect(response).to have_http_status(:forbidden)
    expect(after_calls).to eq(0)
  end

  it "runs OAuth account-creation after hooks after the identity is signed in" do
    observed = []
    oauth_hash = OmniAuth::AuthHash.new(provider: "google_oauth2", uid: "phased-oauth", info: {email: "phased-oauth@example.com"})
    preserve_hooks(Users::OmniAuthsController, :oauth_account_creation) do
      Users::OmniAuthsController.after_oauth_account_creation do |_account, identity|
        observed << (current_identity == identity)
      end

      get "/users/auth/google_oauth2/callback", env: {"omniauth.auth" => oauth_hash}
    end

    expect(observed).to eq([true])
  end

  it "runs sign-out after hooks after Warden has removed the identity" do
    user = create(:user)
    observed = []
    preserve_hooks(Users::SessionsController, :sign_out) do
      Users::SessionsController.after_sign_out { observed << current_identity }
      sign_in(user)
      delete "/users/sign_out"
    end

    expect(observed).to eq([nil])
  end

  it "runs impersonation after hooks after the target becomes current" do
    organisation = create(:organisation)
    admin = create(:user, organisation: organisation)
    target = create(:user, organisation: organisation)
    observed = []
    allow_any_instance_of(Users::ImpersonationsController).to receive(:authorize_impersonation!).and_return(true)
    preserve_hooks(Users::ImpersonationsController, :impersonation_start) do
      Users::ImpersonationsController.after_impersonation_start do |_original, target_identity|
        observed << (current_identity == target_identity)
      end
      sign_in(admin)
      post "/users/impersonations/#{target.id}"
    end

    expect(observed).to eq([true])
  end
end
