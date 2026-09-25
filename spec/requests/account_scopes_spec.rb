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
    stub_const("LinkedAccounts::ImpersonationsController", Class.new(Vouch::ImpersonationsController) do
      auth_scope :account
      impersonator_scope :admin
      private
      def authorize_impersonation! = true
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
      impersonator_scopes :member, :admin

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
      def account_page
        authenticate_account!
        render json: {account: current_account.id} unless performed?
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
      post "/account_impersonations/:id", to: "linked_accounts/impersonations#create"
      get "/linked_status", to: "linked_status#show"
      get "/account_page", to: "linked_status#account_page"
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

    TwoFactorCredential.two_factor_auth_name :totp
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
    expect(status).to include("account" => account.id, "member" => first_target.id, "admin" => nil)

    post "/linked_admins/impersonations/#{second_target.id}"
    expect(status).to include("account" => account.id, "admin" => second_target.id, "member" => nil)

    delete "/linked_admins/impersonations"
    expect(status).to include("account" => account.id, "member" => first_target.id, "admin" => nil)

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

  def start_member_impersonation(target)
    account_login
    get "/linked_admins/sign_in"
    post "/linked_members/impersonations/#{target.id}"
    expect(response).to redirect_to("/")
  end

  it "keeps account guards on the operator and rejects GET and POST membership switching" do
    target = create(:user)
    other_membership = create(:user, account: target.account)
    start_member_impersonation(target)

    get "/account_page"
    expect(response.parsed_body).to eq("account" => account.id)
    get "/protected_page"
    expect(response).to have_http_status(:ok)
    get "/linked_members/sign_in"
    expect(response).to have_http_status(:forbidden)
    post "/linked_members/sign_in", params: {identity_id: other_membership.id}
    expect(response).to have_http_status(:forbidden)
    get "/linked_admins/sign_in"
    expect(response).to have_http_status(:forbidden)
    expect(status).to include("account" => account.id, "member" => target.id, "admin" => nil)
  end

  it "rejects account login and registration while impersonating without modifying the operator session" do
    target = create(:user)
    start_member_impersonation(target)
    post "/linked_accounts/sign_in", params: {email_address: target.account.email_address, password: "password123"}
    expect(response).to have_http_status(:forbidden)
    expect do
      post "/linked_accounts/sign_up", params: {account: {email_address: "blocked@example.com", password: "password123"}}
    end.not_to change(Account, :count)
    expect(response).to have_http_status(:forbidden)
    expect(status).to include("account" => account.id, "member" => target.id)
  end

  it "authorizes exact impersonation without demanding the target's MFA" do
    target = create(:user)
    policy = Class.new(Vouch::AuthenticationPolicy) do
      def membership_mfa_requirements(_account, identity:, **)
        {credential_methods: [:totp], max_age: 60} if identity.email_address == "mfa-target@example.com"
      end
    end.new
    target.account.update!(email_address: "mfa-target@example.com")
    allow(Vouch.configuration).to receive(:authentication_policy).and_return(policy)
    start_member_impersonation(target)
    get "/protected_page"
    expect(response).to have_http_status(:ok)
    expect(status).to include("account" => account.id, "member" => target.id)
  end

  it "invalidates the target if its tenant changes and still allows returning to the operator" do
    target = create(:user)
    start_member_impersonation(target)
    target.update!(organisation: create(:organisation))
    expect(status).to include("account" => account.id, "member" => nil)
    delete "/linked_members/impersonations"
    expect(status).to include("account" => account.id, "admin" => membership.id)
  end

  it "invalidates the target when its credentials owner changes" do
    target = create(:user)
    start_member_impersonation(target)
    target.update!(account: create(:account))
    expect(status).to include("account" => account.id, "member" => nil)
  end

  it "selects an explicit authenticated operator when multiple allowed scopes are active" do
    LinkedMembers::ImpersonationsController.impersonator_scopes :admin, :member
    target = create(:user)
    account_login
    get "/linked_admins/sign_in"
    get "/linked_members/sign_in"
    post "/linked_members/impersonations/#{target.id}"
    expect(response).to have_http_status(:unprocessable_content)
    post "/linked_members/impersonations/#{target.id}", params: {impersonator_scope: "account"}
    expect(response).to have_http_status(:forbidden)
    post "/linked_members/impersonations/#{target.id}", params: {impersonator_scope: "admin"}
    expect(response).to redirect_to("/")
    expect(status).to include("account" => account.id, "member" => target.id, "true_admin" => membership.id)
  end

  it "does not accept an unauthenticated allowed scope or an operator id from the request" do
    LinkedMembers::ImpersonationsController.impersonator_scopes :admin, :member
    account_login
    get "/linked_members/sign_in"
    post "/linked_members/impersonations/#{create(:user).id}", params: {impersonator_scope: "admin", impersonator_id: membership.id}
    expect(response).to have_http_status(:forbidden)
  end

  it "authorizes nested targets as the original operator and cannot change that operator" do
    LinkedMembers::ImpersonationsController.impersonator_scopes :admin, :member
    target, nested = create_list(:user, 2)
    seen = []
    allow_any_instance_of(LinkedMembers::ImpersonationsController).to receive(:authorize_impersonation!) do |controller|
      seen << controller.send(:impersonator).id
    end
    start_member_impersonation(target)
    post "/linked_members/impersonations/#{nested.id}", params: {impersonator_scope: "member"}
    expect(response).to have_http_status(:forbidden)
    post "/linked_members/impersonations/#{nested.id}"
    expect(response).to redirect_to("/")
    expect(seen).to eq([membership.id, membership.id])
    delete "/linked_members/impersonations"
    expect(status).to include("member" => target.id, "account" => account.id)
  end

  it "rechecks the authorized target relation for every nested start" do
    first, forbidden = create_list(:user, 2)
    allow_any_instance_of(LinkedMembers::ImpersonationsController).to receive(:impersonatable_identities).and_return(User.where(id: first.id))
    start_member_impersonation(first)
    post "/linked_members/impersonations/#{forbidden.id}"
    expect(response).to redirect_to("/")
    expect(status).to include("member" => first.id, "account" => account.id)
    delete "/linked_members/impersonations"
    expect(status).to include("admin" => membership.id)
  end

  it "denies target access immediately after the original account is invalidated" do
    target = create(:user)
    start_member_impersonation(target)
    account.update!(password: "revoked-password123", password_confirmation: "revoked-password123")
    expect(status).to include("account" => nil, "member" => nil, "true_admin" => nil)
    get "/protected_page"
    expect(response).to redirect_to("/linked_members/sign_in")
  end

  it "does not restore a reassigned previous target after nested impersonation" do
    first, nested = create_list(:user, 2)
    start_member_impersonation(first)
    post "/linked_members/impersonations/#{nested.id}"
    first.update!(organisation: create(:organisation))
    delete "/linked_members/impersonations"
    expect(status).to include("account" => account.id, "member" => nil, "admin" => membership.id)
  end

  it "uses the same controller for member operators when they are the only authenticated allowed scope" do
    LinkedMembers::ImpersonationsController.impersonator_scopes :admin, :member
    target = create(:user)
    account_login
    get "/linked_members/sign_in"
    post "/linked_members/impersonations/#{target.id}"
    expect(response).to redirect_to("/")
    expect(status).to include("account" => account.id, "member" => target.id)
    delete "/linked_members/impersonations"
    expect(status).to include("member" => membership.id)
  end

  it "preserves the operator's credentials when nesting from account impersonation into a membership" do
    target = create(:user)
    account_login
    get "/linked_admins/sign_in"
    post "/account_impersonations/#{target.account_id}"
    expect(response).to redirect_to("/")
    post "/linked_members/impersonations/#{target.id}"
    expect(response).to redirect_to("/")
    expect(status).to include("account" => account.id, "member" => target.id)
  end

end
