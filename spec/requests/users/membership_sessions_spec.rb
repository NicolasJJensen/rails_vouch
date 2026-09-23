# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Users::MembershipSessions", type: :request do
  let(:organisation1) { create(:organisation) }
  let(:organisation2) { create(:organisation) }
  let(:account) do
    create(:account, email_address: "multi@example.com",
           password: "password123", password_confirmation: "password123")
  end
  let!(:user1) { create(:user, account: account, organisation: organisation1) }
  let!(:user2) { create(:user, account: account, organisation: organisation2) }
  let!(:credential) do
    account.two_factor_credentials.create!(
      otp_secret: ROTP::Base32.random,
      enabled: true,
      verified_at: Time.current,
      two_factor_enabled_at: Time.current
    )
  end

  before do
    # Stub the protocol methods so we don't need to drive a real TOTP through
    # the request cycle. challenge! returns a fake token that the controller
    # stores in the session; verify_challenge is stubbed per-context below.
    allow_any_instance_of(TwoFactorCredential).to receive(:challenge!).and_return(
      Vouch::Result.ok("fake-token")
    )
  end

  # Establishes a tier-2 (account verified, identity pending) session by going
  # through the full sign-in -> 2FA flow. After this call, the account is
  # bound to the :user_account Warden scope and the response is a redirect
  # to /users/select.
  def establish_pending_account_session
    post "/users/sign_in", params: { email_address: "multi@example.com", password: "password123" }
    follow_redirect!                                          # GET /users/two_factor_challenges
    get "/users/two_factor_challenges/#{credential.id}"       # issues challenge, stores token
    patch "/users/two_factor_challenges/#{credential.id}", params: { code: ROTP::TOTP.new(credential.otp_secret).now }
  end

  def invalidate_selection_after_guard(account)
    callback = :invalidate_selection_after_guard
    Users::MembershipSessionsController.define_method(callback) do
      Account.find(account.id).update!(password: "rotated-password")
    end
    Users::MembershipSessionsController.append_before_action callback
    yield
  ensure
    Users::MembershipSessionsController.skip_before_action callback, raise: false
    Users::MembershipSessionsController.send(:remove_method, callback) if
      Users::MembershipSessionsController.method_defined?(callback)
  end

  describe "GET /users/select" do
    it "redirects to sign-in when no pending selection" do
      get "/users/select"
      expect(response).to redirect_to("/users/sign_in")
    end

    context "with a pending selection" do
      it "renders the identity selection page" do
        establish_pending_account_session
        follow_redirect!
        expect(response).to have_http_status(:ok)
      end

      it "redirects when the pending selection becomes invalid after the guard" do
        account = create(:account)
        create(:user, account: account)
        sign_in_as_account(account)

        invalidate_selection_after_guard(account) { get "/users/select" }

        expect(response).to redirect_to("/users/sign_in")
      end
    end
  end

  describe "tier-2 direct sign-in (sign_in_as_account)" do
    it "renders /users/select without going through credentials again" do
      sign_in_as_account(account)
      get "/users/select"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /users/select" do
    it "redirects to sign-in when no pending selection" do
      post "/users/select", params: { identity_id: user1.id }
      expect(response).to redirect_to("/users/sign_in")
    end

    context "with a pending selection" do
      it "signs in as the selected identity and redirects" do
        establish_pending_account_session

        post "/users/select", params: { identity_id: user1.id }
        expect(response).to redirect_to("/")

        # Confirm we're authenticated — a protected endpoint returns 200
        get "/users/two_factor_credentials"
        expect(response).to have_http_status(:ok)
      end

      it "redirects when the pending selection becomes invalid after the guard" do
        account = create(:account)
        identity = create(:user, account: account)
        sign_in_as_account(account)

        invalidate_selection_after_guard(account) { post "/users/select", params: { identity_id: identity.id } }

        expect(response).to redirect_to("/users/sign_in")
      end
    end
  end
end
