# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Warden Strategies" do
  describe ":password strategy" do
    let(:strategy_class) { Warden::Strategies[:password] }

    it "is registered" do
      expect(strategy_class).not_to be_nil
    end

    describe "#valid?" do
      it "returns true when password is present in params" do
        env = Rack::MockRequest.env_for("/", method: "POST", params: { "password" => "test123" })
        instance = strategy_class.new(env, :user)
        expect(instance).to be_valid
      end

      it "returns false when password is missing" do
        env = Rack::MockRequest.env_for("/", method: "POST", params: { "email_address" => "test@example.com" })
        instance = strategy_class.new(env, :user)
        expect(instance).not_to be_valid
      end

      it "returns false when params are empty" do
        env = Rack::MockRequest.env_for("/", method: "POST", params: {})
        instance = strategy_class.new(env, :user)
        expect(instance).not_to be_valid
      end
    end

    describe "#authenticate!" do
      let(:organisation) { create(:organisation) }
      let(:account) { create(:account, email_address: "strat@example.com", password: "password123", password_confirmation: "password123") }
      let!(:user) { create(:user, account: account, organisation: organisation) }

      def build_strategy(params)
        env = Rack::MockRequest.env_for("/users/sign_in", method: "POST", params: params)
        env["rack.session"] = {}
        strategy_class.new(env, :user)
      end

      context "with valid credentials" do
        it "succeeds and returns the account" do
          instance = build_strategy("email_address" => "strat@example.com", "password" => "password123")
          instance.authenticate!

          expect(instance.user).to eq(account)
        end
      end

      context "when account is not found" do
        it "fails with invalid credentials message" do
          instance = build_strategy("email_address" => "nobody@example.com", "password" => "password123")
          instance.authenticate!

          expect(instance.result).to eq(:failure)
          expect(instance.message).to eq("Invalid credentials.")
        end
      end

      context "when account is locked" do
        before { account.update!(locked_at: Time.current, failed_attempts: 5) }

        it "fails with generic credentials message" do
          instance = build_strategy("email_address" => "strat@example.com", "password" => "password123")
          instance.authenticate!

          expect(instance.result).to eq(:failure)
          expect(instance.message).to eq("Invalid credentials.")
        end
      end

      context "with wrong password" do
        it "fails and increments failed_attempts" do
          instance = build_strategy("email_address" => "strat@example.com", "password" => "wrong")
          instance.authenticate!

          expect(instance.result).to eq(:failure)
          expect(instance.message).to eq("Invalid credentials.")
          expect(account.reload.failed_attempts).to eq(1)
        end
      end
    end
  end

  # NOTE: the old :two_factor_verification Warden strategy was removed in
  # the otp-courier refactor. 2FA verification now lives in
  # TwoFactorChallengeController#update, which holds the per-credential
  # challenge token in the session and calls
  # TwoFactorable#verify_challenge directly. See spec/requests/users/
  # two_factor_challenge_spec.rb for the request-level coverage.
end
