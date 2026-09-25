# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Users::TwoFactorChallenge", type: :request do
  let(:organisation) { create(:organisation) }
  let(:account) { create(:account, email_address: "twofa@example.com", password: "password123", password_confirmation: "password123") }
  let!(:user) { create(:user, account: account, organisation: organisation) }
  let!(:credential) do
    account.two_factor_credentials.create!(
      otp_secret: ROTP::Base32.random,
      enabled: true,
      verified_at: Time.current,
      two_factor_enabled_at: Time.current
    )
  end

  # Establishes a 2FA-pending session by performing the login flow.
  # Must be called inline in each example (not in before blocks) because
  # RSpec request specs tie cookie/session state to individual HTTP flows.
  def establish_2fa_session
    post "/users/sign_in", params: { email_address: "twofa@example.com", password: "password123" }
    follow_redirect!
  end

  before do
    account.enable_two_factor!

    # The dummy TwoFactorCredential delegates to ROTP when otp_secret is
    # set. For request specs we stub the protocol-level methods so we
    # don't need to drive an actual TOTP code through the request cycle.
    allow_any_instance_of(TwoFactorCredential).to receive(:challenge!).and_return(
      Vouch::Result.ok("fake-token")
    )
  end

  describe "without 2FA session" do
    it "GET /users/two_factor_challenges redirects to sign-in" do
      get "/users/two_factor_challenges"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "GET /users/two_factor_challenges/:id redirects to sign-in" do
      get "/users/two_factor_challenges/#{credential.id}"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "PATCH /users/two_factor_challenges/:id redirects to sign-in" do
      patch "/users/two_factor_challenges/#{credential.id}", params: { code: "123456" }
      expect(response).to redirect_to("/users/sign_in")
    end
  end

  describe "with 2FA session" do
    describe "POST /users/recovery" do
      it "consumes an account recovery code in the pending MFA flow and signs in" do
        code = account.generate_recovery_codes!.value.first
        establish_2fa_session

        post "/users/recovery", params: {recovery_owner_type: "account", recovery_code: code}

        expect(response).to redirect_to("/")
        expect(account.recovery_codes_remaining).to eq(9)
        expect(flash[:notice]).to include("recovery code")
      end

      it "does not allow a recovery code to be replayed" do
        code = account.generate_recovery_codes!.value.first
        establish_2fa_session
        post "/users/recovery", params: {recovery_owner_type: "account", recovery_code: code}
        delete "/users/sign_out"

        establish_2fa_session
        post "/users/recovery", params: {recovery_owner_type: "account", recovery_code: code}
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "shows the recovery warning after membership selection completes" do
        create(:user, account: account)
        code = account.generate_recovery_codes!.value.first
        establish_2fa_session

        post "/users/recovery", params: {recovery_owner_type: "account", recovery_code: code}
        expect(response).to redirect_to("/users/select")
        follow_redirect!
        post "/users/select", params: {identity_id: user.id}

        expect(response).to redirect_to("/")
        expect(flash[:notice]).to include("recovery code")
      end
    end

    describe "GET /users/two_factor_challenges" do
      it "renders the credential selection page" do
        establish_2fa_session
        expect(response).to have_http_status(:ok)
      end
    end

    describe "GET /users/two_factor_challenges/:id" do
      it "issues a challenge and renders the code entry form" do
        establish_2fa_session
        get "/users/two_factor_challenges/#{credential.id}"
        expect(response).to have_http_status(:ok)
      end
    end

    describe "POST /users/two_factor_challenges/:id/send_code" do
      it "re-issues the challenge and renders the show template" do
        establish_2fa_session
        post "/users/two_factor_challenges/#{credential.id}/send_code"
        expect(response).to have_http_status(:ok)
      end

      it "redirects for a non-existent credential" do
        establish_2fa_session
        post "/users/two_factor_challenges/0/send_code"
        expect(response).to redirect_to("/users/two_factor_challenges")
      end
    end

    describe "PATCH /users/two_factor_challenges/:id" do
      context "with a valid code" do
        it "signs in and redirects to root" do
          establish_2fa_session
          get "/users/two_factor_challenges/#{credential.id}" # issues challenge, stores token
          patch "/users/two_factor_challenges/#{credential.id}", params: { code: ROTP::TOTP.new(credential.otp_secret).now }
          expect(response).to redirect_to("/")
        end

        it "resets failed_attempts on the account" do
          account.update!(failed_attempts: 3)
          establish_2fa_session
          get "/users/two_factor_challenges/#{credential.id}"
          patch "/users/two_factor_challenges/#{credential.id}", params: { code: ROTP::TOTP.new(credential.otp_secret).now }
          expect(account.reload.failed_attempts).to eq(0)
        end
      end

      context "with an invalid code" do
        it "re-renders with 422 status" do
          establish_2fa_session
          get "/users/two_factor_challenges/#{credential.id}"
          patch "/users/two_factor_challenges/#{credential.id}", params: { code: "000000" }
          expect(response).to have_http_status(422)
        end
      end
    end
  end

  describe "attempts exceeded" do
    it "redirects to sign-in when the credential is two-factor locked" do
      # Re-stub challenge! to return locked (the top-level before stubs ok
      # for the happy-path tests; here we want the locked branch).
      allow_any_instance_of(TwoFactorCredential).to receive(:challenge!).and_return(
        Vouch::Result.locked
      )
      credential.update!(two_factor_locked_at: Time.current)
      establish_2fa_session
      get "/users/two_factor_challenges/#{credential.id}"
      expect(response).to redirect_to("/users/sign_in")
    end
  end
end
