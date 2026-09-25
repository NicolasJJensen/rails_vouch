# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Account and membership sessions", type: :request do
  let(:account) { create(:account, password: "password123", password_confirmation: "password123") }
  let!(:membership) { create(:user, account: account) }

  before do
    @original_mappings = Vouch.mappings.dup
    stub_const("LinkedAccounts", Module.new)
    stub_const("LinkedMembers", Module.new)
    stub_const("LinkedAdmins", Module.new)
    stub_const("LinkedAccounts::SessionsController", Class.new(Vouch::SessionsController) do
      auth_scope :account
      def new
        render plain: "Account sign in"
      end
    end)
    stub_const("LinkedAccounts::RegistrationsController", Class.new(Vouch::RegistrationsController) do
      auth_scope :account
      private
      def after_sign_up_path
        "/welcome"
      end
    end)
    stub_const("LinkedAccounts::TwoFactorChallengeController", Class.new(Vouch::TwoFactorChallengeController) do
      auth_scope :account
      def default_render
        render plain: "Second factor"
      end
    end)
    stub_const("LinkedAccounts::OmniAuthsController", Class.new(Vouch::OmniAuthsController) do
      auth_scope :account
      private
      def after_sign_up_path
        "/oauth-welcome"
      end
      def after_sign_in_path
        "/oauth-home"
      end
    end)
    stub_const("LinkedMembers::SessionsController", Class.new(Vouch::MembershipSessionsController) do
      auth_scope :member
    end)
    stub_const("LinkedAdmins::SessionsController", Class.new(Vouch::MembershipSessionsController) do
      auth_scope :admin
    end)
    stub_const("LinkedMembers::ImpersonationsController", Class.new(Vouch::ImpersonationsController) do
      auth_scope :member
      impersonator_scope :admin

      private

      def authorize_impersonation! = true
    end)
    stub_const("LinkedAdmins::ImpersonationsController", Class.new(Vouch::ImpersonationsController) do
      auth_scope :admin
      impersonator_scope :member

      private

      def authorize_impersonation! = true
    end)
    stub_const("LinkedStatusController", Class.new(ApplicationController) do
      def show
        render json: {
          account: current_account&.id,
          member: current_account_member&.id,
          short_member: current_member&.id,
          admin: current_admin&.id,
          true_admin: true_admin&.id
        }
      end
      def protected_page
        authenticate_member!
        render plain: "protected" unless performed?
      end
    end)
    Rails.application.routes.draw do
      Vouch.routes(self) do |auth|
        auth.scope :account, model: "Account", path: "linked_accounts" do
          auth.sessions
          auth.registrations
          auth.oauth_callbacks
          auth.two_factor challenge_controller: "linked_accounts/two_factor_challenge"
        end
        auth.scope :member, account_scope: :account, identity: "User", tenant: "Organisation", path: "linked_members" do
          auth.sessions
          auth.impersonation controller: "linked_members/impersonations"
        end
        auth.scope :admin, account_scope: :account, identity: "User", tenant: "Organisation", path: "linked_admins" do
          auth.sessions
          auth.impersonation controller: "linked_admins/impersonations"
        end
      end
      get "/linked_status", to: "linked_status#show"
      get "/protected_page", to: "linked_status#protected_page"
      root "rails/health#show"
    end
  end

  after do
    Vouch.mappings.replace(@original_mappings)
    Vouch::ApplicationHelpers.refresh!
    Rails.application.reload_routes!
  end

  def account_login
    post "/linked_accounts/sign_in", params: { email_address: account.email_address, password: "password123" }
  end

  def status
    get "/linked_status"
    response.parsed_body
  end

  it "establishes only the account when logging in directly" do
    account_login
    expect(response).to redirect_to("/")
    expect(status).to include("account" => account.id, "member" => nil, "admin" => nil)
  end

  it "continues a protected membership request through account authentication" do
    get "/protected_page", params: { page: 2 }
    expect(response).to redirect_to("/linked_members/sign_in")
    follow_redirect!
    expect(response).to redirect_to("/linked_accounts/sign_in")
    account_login
    expect(response).to redirect_to("/linked_members/sign_in")
    follow_redirect!
    expect(response).to redirect_to("/protected_page?page=2")
    expect(status).to include("account" => account.id, "member" => membership.id, "short_member" => membership.id)
  end

  it "retains sibling memberships and the parent when signing out of a membership" do
    account_login
    get "/linked_members/sign_in"
    get "/linked_admins/sign_in"
    expect(status).to include("member" => membership.id, "admin" => membership.id)
    delete "/linked_members/sign_out"
    expect(status).to include("account" => account.id, "member" => nil, "admin" => membership.id)
    delete "/linked_accounts/sign_out"
    expect(status).to include("account" => nil, "member" => nil, "admin" => nil)
  end

  it "requires selection for several memberships and rejects foreign memberships" do
    second = create(:user, account: account)
    foreign = create(:user)
    account_login
    get "/linked_members/sign_in"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Choose a membership")
    post "/linked_members/sign_in", params: { identity_id: foreign.id }
    expect(response).to have_http_status(:forbidden)
    post "/linked_members/sign_in", params: { identity_id: second.id }
    expect(response).to redirect_to("/")
    expect(status).to include("account" => account.id, "member" => second.id)
  end

  it "denies selection without memberships while retaining the account session" do
    membership.destroy!
    account_login
    get "/linked_members/sign_in"
    expect(response).to have_http_status(:forbidden)
    expect(status).to include("account" => account.id, "member" => nil)
  end

  it "does not expose an orphaned membership without an account session" do
    login_as(membership, scope: :member)
    expect(status).to include("account" => nil, "member" => nil)
  end

  it "rejects a membership belonging to a different authenticated account" do
    other = create(:account)
    login_as(other, scope: :account)
    login_as(membership, scope: :member)
    expect(status).to include("account" => other.id, "member" => nil)
  end

  it "revokes account and dependent memberships after a password change" do
    account_login
    get "/linked_members/sign_in"
    account.update!(password: "replacement123", password_confirmation: "replacement123")
    expect(status).to include("account" => nil, "member" => nil)
  end

  it "uses the registration redirect when the account is created" do
    post "/linked_accounts/sign_up", params: { account: {
      email_address: "new-account@example.com", password: "password123", password_confirmation: "password123"
    } }
    expect(response).to redirect_to("/welcome")
  end
  it "does not establish an account before MFA, then resumes the requested membership" do
    credential = account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    get "/protected_page"
    follow_redirect!
    account_login
    expect(response).to redirect_to("/linked_accounts/two_factor_challenges")
    expect(status).to include("account" => nil, "member" => nil)
    get "/linked_accounts/two_factor_challenges/#{credential.id}"
    patch "/linked_accounts/two_factor_challenges/#{credential.id}",
      params: { code: ROTP::TOTP.new(credential.otp_secret).now }
    expect(response).to redirect_to("/linked_members/sign_in")
    follow_redirect!
    expect(response).to redirect_to("/protected_page")
    expect(status).to include("account" => account.id, "member" => membership.id)
  end

  it "uses the parent challenge route for a membership-specific MFA requirement and only binds the membership after proof" do
    policy = Class.new(Vouch::AuthenticationPolicy) do
      def membership_mfa_requirements(_account, identity:, tenant:, controller:)
        {credential_types: ["TwoFactorCredential"], credential_methods: [:totp], allow_recovery_codes: false}
      end
    end
    stub_const("LinkedMembershipMfaPolicy", policy)
    original_policy = Vouch.configuration.authentication_policy
    Vouch.configuration.authentication_policy = LinkedMembershipMfaPolicy

    credential = account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    account_login
    get "/linked_accounts/two_factor_challenges/#{credential.id}"
    patch "/linked_accounts/two_factor_challenges/#{credential.id}", params: {code: ROTP::TOTP.new(credential.otp_secret).now}
    expect(response).to redirect_to("/")

    TwoFactorCredential.two_factor_authentication_method = :totp
    get "/linked_members/sign_in"
    expect(response).to redirect_to("/linked_accounts/two_factor_challenges")
    expect(status).to include("account" => account.id, "member" => nil)

    get "/linked_accounts/two_factor_challenges/#{credential.id}"
    travel 31.seconds do
      patch "/linked_accounts/two_factor_challenges/#{credential.id}", params: {code: ROTP::TOTP.new(credential.otp_secret).now}
      expect(response).to redirect_to("/linked_members/sign_in")
      follow_redirect!
      expect(status).to include("account" => account.id, "member" => membership.id)
    end
  ensure
    Vouch.configuration.authentication_policy = original_policy
    TwoFactorCredential.two_factor_authentication_method = nil
  end

  it "keeps registration intent through MFA and membership selection" do
    allow_any_instance_of(ApplicationController).to receive(:after_sign_up_path_for).and_return("/onboarding")
    allow_any_instance_of(LinkedAccounts::RegistrationsController).to receive(:build_tenant) do |_controller, record|
      Organisation.new(name: "#{record.email_address}'s Organisation")
    end
    allow_any_instance_of(LinkedAccounts::RegistrationsController).to receive(:build_identity) do |_, record, tenant:|
      tenant.users.build(account: record)
    end
    LinkedAccounts::RegistrationsController.set_hook(:sign_up, :after) do |record|
      record.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
        verified_at: Time.current, two_factor_enabled_at: Time.current)
      record.enable_two_factor!
      Organisation.create!(name: "#{record.email_address}'s Second Organisation").users.create!(account: record)
    end
    get "/linked_members/sign_in"
    post "/linked_accounts/sign_up", params: { account: {
      email_address: "mfa-signup@example.com", password: "password123", password_confirmation: "password123"
    } }
    expect(response).to redirect_to("/linked_accounts/two_factor_challenges")
    created = Account.find_by!(email_address: "mfa-signup@example.com")
    credential = created.two_factor_credentials.first
    get "/linked_accounts/two_factor_challenges/#{credential.id}"
    patch "/linked_accounts/two_factor_challenges/#{credential.id}",
      params: { code: ROTP::TOTP.new(credential.otp_secret).now }
    expect(response).to redirect_to("/linked_members/sign_in")
    follow_redirect!
    expect(response).to have_http_status(:ok)
    post "/linked_members/sign_in", params: { identity_id: created.users.first.id }
    expect(response).to redirect_to("/onboarding")
  end

  it "rejects a membership removed after the selection form was shown" do
    create(:user, account: account)
    account_login
    get "/linked_members/sign_in"
    membership.destroy!
    post "/linked_members/sign_in", params: { identity_id: membership.id }
    expect(response).to have_http_status(:forbidden)
    expect(status).to include("account" => account.id, "member" => nil)
  end

  it "does not publish a membership when its lifecycle callback halts" do
    LinkedMembers::SessionsController.before_sign_in { throw :abort }
    account_login
    get "/linked_members/sign_in"
    expect(response).to have_http_status(:forbidden)
    expect(status).to include("account" => account.id, "member" => nil)
  end

  it "restores nested cross-scope impersonations and the original administrator" do
    first_target = create(:user, account: create(:account), organisation: membership.organisation)
    second_target = create(:user, account: create(:account), organisation: membership.organisation)

    account_login
    get "/linked_admins/sign_in"
    expect(status).to include("admin" => membership.id)

    post "/linked_members/impersonations/#{first_target.id}"
    expect(status).to include("account" => first_target.account_id, "member" => first_target.id, "admin" => nil)

    post "/linked_admins/impersonations/#{second_target.id}"
    expect(status).to include("account" => second_target.account_id, "admin" => second_target.id, "member" => nil)

    delete "/linked_admins/impersonations"
    expect(status).to include("account" => first_target.account_id, "member" => first_target.id, "admin" => nil)

    delete "/linked_members/impersonations/all"
    expect(status).to include("account" => account.id, "admin" => membership.id, "true_admin" => membership.id)
  end

  it "ends impersonation without restoring an operator whose credentials changed" do
    target = create(:user, account: create(:account), organisation: membership.organisation)
    account_login
    get "/linked_admins/sign_in"
    post "/linked_members/impersonations/#{target.id}"

    account.update!(password: "rotated-password123", password_confirmation: "rotated-password123")
    delete "/linked_members/impersonations"

    expect(response).to have_http_status(:unprocessable_content)
    expect(status).to include("account" => nil, "member" => nil, "admin" => nil)
  end

  it "clears the complete impersonation stack when signing out" do
    target = create(:user, account: create(:account), organisation: membership.organisation)
    account_login
    get "/linked_admins/sign_in"
    post "/linked_members/impersonations/#{target.id}"

    delete "/linked_accounts/sign_out"

    expect(status).to include("account" => nil, "member" => nil, "admin" => nil)
  end

  it "uses the sign-up redirect for a new OAuth account and sign-in for an existing account" do
    auth_hash = OmniAuth::AuthHash.new(provider: "example", uid: "new", info: {email: "new-oauth@example.com"})
    get "/linked_accounts/auth/example/callback", env: {"omniauth.auth" => auth_hash}
    expect(response).to redirect_to("/oauth-welcome")
    delete "/linked_accounts/sign_out"
    get "/linked_accounts/auth/example/callback", env: {"omniauth.auth" => auth_hash}
    expect(response).to redirect_to("/oauth-home")
  end

end
