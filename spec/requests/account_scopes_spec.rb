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
    stub_const("LinkedAccounts::TwoFactorCredentialsController", Class.new(Vouch::TwoFactorCredentialsController) do
      auth_scope :account

      def index
        super
        render json: { account: current_account.id, credentials: @credentials.map(&:id) }
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

    end)
    stub_const("LinkedAdmins::ImpersonationsController", Class.new(Vouch::ImpersonationsController) do
      auth_scope :admin
      impersonator_scopes :member, :admin

      private

    end)
    stub_const("LinkedStatusController", Class.new(ApplicationController) do
      def show
        render json: {
          account: current_account&.id,
          member: current_account_member&.id,
          short_member: current_member&.id,
          admin: current_admin&.id,
          true_admin: true_admin&.id,
          true_account: true_account&.id,
          true_member: true_member&.id
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
      post "/linked_accounts/auth/:provider", to: "oauth_requests#create"
      Vouch.routes(self) do |auth|
        auth.scope :account, model: "Account", path: "linked_accounts" do
          auth.sessions controller: "linked_accounts/sessions"
          auth.registrations controller: "linked_accounts/registrations"
          auth.oauth_callbacks controller: "linked_accounts/omni_auths", registration: :automatic
          auth.two_factor_challenges controller: "linked_accounts/two_factor_challenge"
          auth.two_factor_credentials controller: "linked_accounts/two_factor_credentials"
          auth.recovery_codes
        end
        auth.scope :member, account_scope: :account, identity: "User", tenant: "Organisation", path: "linked_members" do
          auth.sessions controller: "linked_members/sessions"
          auth.impersonation controller: "linked_members/impersonations"
        end
        auth.scope :admin, account_scope: :account, identity: "User", tenant: "Organisation", path: "linked_admins" do
          auth.sessions controller: "linked_admins/sessions"
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

  it "does not select or sign out a membership after the host denies the action" do
    account_login
    %i[new create].each do |action|
      LinkedMembers::SessionsController.define_method(action) { head :forbidden; super() }
    end
    get "/linked_members/sign_in"
    expect(response).to have_http_status(:forbidden)
    expect(request.env.fetch("warden").user(:member)).to be_nil
    post "/linked_members/sign_in", params: { identity_id: membership.id }
    expect(response).to have_http_status(:forbidden)
    expect(request.env.fetch("warden").user(:member)).to be_nil
    %i[new create].each { |action| LinkedMembers::SessionsController.remove_method(action) }
    get "/linked_members/sign_in"
    expect(request.env.fetch("warden").user(:member)).to eq(membership)
    LinkedMembers::SessionsController.define_method(:destroy) { head :forbidden; super() }
    delete "/linked_members/sign_out"
    expect(response).to have_http_status(:forbidden)
    expect(request.env.fetch("warden").user(:member)).to eq(membership)
    expect(request.env.fetch("warden").user(:account)).to eq(account)
  end

  it "confirms a membership guard through its credentials controller" do
    LinkedStatusController.require_recent_authentication(scope: :member, within: 1.minute, only: :protected_page)
    account_login
    original_proof = request.session[Vouch::Session.key_for(:account, :confirmation)].fetch("proof").deep_dup
    get "/linked_members/sign_in"
    get "/protected_page"
    expect(response).to have_http_status(:ok)
    expect(request.session[Vouch::Session.key_for(:member, :confirmation)].fetch("proof")).to eq(original_proof)
    travel 2.minutes do
      get "/protected_page"
      expect(response).to redirect_to("/linked_accounts/confirmation?confirmation_scope=member")
      post "/linked_accounts/confirmation", params: { confirmation_scope: :member, password: "password123" }
      expect(response).to redirect_to("/protected_page")
      follow_redirect!
      expect(response).to have_http_status(:ok)
      expect(request.env.fetch("warden").user(:member)).to eq(membership)
    end
  end

  it "uses the original operator's password during full-account impersonation" do
    LinkedStatusController.require_recent_authentication(scope: :account, within: 1.minute, only: :account_page)
    LinkedAccounts::SessionsController.define_method(:confirm) do
      super() { |result| head :unprocessable_entity unless result.ok? }
    end
    target = create(:account, password: "target-secret", password_confirmation: "target-secret")
    account_login
    get "/linked_admins/sign_in"
    post "/account_impersonations/#{target.id}"
    expect(response).to have_http_status(:redirect)
    get "/account_page"
    expect(response).to redirect_to("/linked_accounts/confirmation?confirmation_scope=account")
    post "/linked_accounts/confirmation", params: { password: "target-secret" }
    expect(response).to have_http_status(:unprocessable_entity)
    post "/linked_accounts/confirmation", params: { password: "password123" }
    expect(response).to redirect_to("/account_page")
    follow_redirect!
    expect(response.parsed_body).to eq("account" => target.id)
    expect(request.env.fetch("warden").user(:account)).to eq(target)
    expect(request.session[Vouch::Session.key_for(:account, :evidence)]).to be_nil
  end

  it "yields automatic membership completion once before the default response" do
    observed = []
    LinkedMembers::SessionsController.define_method(:new) do
      super() do |result|
        observed << result.status
        render json: { identity_id: result.metadata.fetch(:identity).id }
      end
    end
    account_login

    get "/linked_members/sign_in"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("identity_id" => membership.id)
    expect(response.headers["Location"]).to be_nil
    expect(observed).to eq([:ok])
    expect(status).to include("account" => account.id, "member" => membership.id)
  end

  it "does not fabricate an original account absent from the captured sessions" do
    reference = Vouch::ImpersonationStack.send(:reference_for, Vouch.mapping_for(:admin), membership)
    stored = { Vouch::ImpersonationStack::SESSION_KEY => [{ "source" => reference, "contexts" => [] }] }

    expect(Vouch::ImpersonationStack.original(warden: nil, session: stored, scope: :account)).to be_nil
  end

  it "changes the authentication context across sign-out and another login of the same account" do
    account_login
    original = Vouch::AuthenticationSession.context_id_for(request.session)
    get "/account_page"
    expect(Vouch::AuthenticationSession.context_id_for(request.session)).to eq(original)

    delete "/linked_accounts/sign_out"
    expect(request.session[Vouch::AuthenticationSession::CONTEXT_KEY]).to be_nil
    account_login
    expect(Vouch::AuthenticationSession.context_id_for(request.session)).not_to eq(original)
  end

  it "changes the authentication context when entering and leaving impersonation" do
    target = create(:user)
    account_login
    get "/linked_admins/sign_in"
    original = Vouch::AuthenticationSession.context_id_for(request.session)
    post "/account_impersonations/#{target.account_id}"
    impersonating = Vouch::AuthenticationSession.context_id_for(request.session)
    expect(impersonating).not_to eq(original)
    LinkedMembers::ImpersonationsController.impersonator_scopes :member
    get "/linked_members/sign_in"
    post "/linked_members/impersonations/#{create(:user).id}"
    nested = Vouch::AuthenticationSession.context_id_for(request.session)
    delete "/linked_members/impersonations"
    expect(Vouch::AuthenticationSession.context_id_for(request.session)).not_to eq(nested)
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

  it "publishes MFA as a list and leaves additional membership requirements to the application" do
    credential = account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    account_login
    get "/linked_accounts/two_factor_challenges/#{credential.id}"
    patch "/linked_accounts/two_factor_challenges/#{credential.id}", params: {code: ROTP::TOTP.new(credential.otp_secret).now}
    expect(response).to redirect_to("/")
    evidence = request.session[Vouch::Session.key_for(:account, :evidence)]
    expect(evidence).to be_an(Array)
    expect(evidence.size).to eq(1)
    expect(evidence.first).to include("method" => "two_factor", "credential_type" => "TwoFactorCredential")

    get "/linked_members/sign_in"
    expect(response).to redirect_to("/")
    expect(status).to include("account" => account.id, "member" => membership.id)
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

    expect(response).to redirect_to("/")
    expect(flash[:alert]).to include("Impersonation access has ended")
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
    oauth_callback "/linked_accounts/auth/example/callback", auth: auth_hash, purpose: :register
    expect(response).to redirect_to("/oauth-welcome")
    delete "/linked_accounts/sign_out"
    oauth_callback "/linked_accounts/auth/example/callback", auth: auth_hash, purpose: :sign_in
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
    get "/linked_status"
    expect(response).to redirect_to("/")
    expect(status).to include("account" => account.id, "admin" => membership.id)
  end

  it "invalidates the target when its credentials owner changes" do
    target = create(:user)
    start_member_impersonation(target)
    target.update!(account: create(:account))
    get "/linked_status"
    expect(response).to redirect_to("/")
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
    LinkedMembers::ImpersonationsController.define_method(:create) do
      seen << impersonator.id
      super()
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
    expect(response).to have_http_status(:not_found)
    expect(status).to include("member" => first.id, "account" => account.id)
    delete "/linked_members/impersonations"
    expect(status).to include("admin" => membership.id)
  end

  it "denies target access immediately after the original account is invalidated" do
    target = create(:user)
    start_member_impersonation(target)
    account.update!(password: "revoked-password123", password_confirmation: "revoked-password123")
    get "/linked_status"
    expect(response).to redirect_to("/")
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

  it "retains the impersonated account when its selected membership impersonates another membership" do
    target = create(:user)
    foreign = create(:user)
    LinkedMembers::ImpersonationsController.impersonator_scopes :member
    account_login
    get "/linked_admins/sign_in"
    post "/account_impersonations/#{target.account_id}"
    expect(response).to redirect_to("/")
    expect(status).to include("account" => target.account_id, "member" => nil, "admin" => nil,
      "true_account" => account.id, "true_admin" => membership.id, "true_member" => nil)

    get "/linked_members/sign_in"
    expect(response).to redirect_to("/")
    expect(status).to include("account" => target.account_id, "member" => target.id)
    post "/linked_members/impersonations/#{foreign.id}"
    expect(response).to redirect_to("/")
    expect(status).to include("account" => target.account_id, "member" => foreign.id,
      "true_account" => account.id, "true_admin" => membership.id, "true_member" => nil)

    get "/linked_members/sign_in"
    expect(response).to have_http_status(:forbidden)
    get "/account_page"
    expect(response.parsed_body).to eq("account" => target.account_id)
    delete "/linked_members/impersonations"
    expect(status).to include("account" => target.account_id, "member" => target.id)
  end

  it "unwinds a revoked nested grant to the preceding authorized target before rendering" do
    first, nested = create_list(:user, 2)
    start_member_impersonation(first)
    post "/linked_members/impersonations/#{nested.id}"
    allow_any_instance_of(ApplicationController).to receive(:impersonation_allowed?) do |_controller, context|
      context.target != nested
    end

    get "/linked_status"

    expect(response).to redirect_to("/")
    expect(flash[:alert]).to include("Impersonation access has ended")
    expect(status).to include("account" => account.id, "member" => first.id)
    expect(Vouch::ImpersonationStack.send(:entries, request.session).size).to eq(1)
  end

  it "removes every dependent frame when the first grant expires" do
    first, nested = create_list(:user, 2)
    start_member_impersonation(first)
    post "/linked_members/impersonations/#{nested.id}"
    observed = []
    expires_at = 1.minute.from_now
    allow_any_instance_of(ApplicationController).to receive(:impersonation_allowed?) do |_controller, context|
      observed << [context.mode, context.operator.id, context.target.id]
      context.target != first || Time.current < expires_at
    end

    travel_to(expires_at + 1.second) { get "/protected_page" }

    expect(response).to redirect_to("/")
    expect(observed).to eq([[:membership, membership.id, first.id]])
    expect(request.session[Vouch::ImpersonationStack::SESSION_KEY]).to be_nil
    expect(status).to include("account" => account.id, "member" => nil, "admin" => membership.id)
  end

  it "honors sign-out when a nested grant has expired instead of leaving the earlier session active" do
    first, nested = create_list(:user, 2)
    start_member_impersonation(first)
    post "/linked_members/impersonations/#{nested.id}"
    allow_any_instance_of(ApplicationController).to receive(:impersonation_allowed?).and_return(false)

    delete "/linked_members/sign_out"

    expect(response).to redirect_to("/linked_members/sign_in")
    expect(request.session[Vouch::ImpersonationStack::SESSION_KEY]).to be_nil
    expect(status).to include("account" => nil, "member" => nil, "admin" => nil)
  end

  it "honors stop-all when only a nested grant has expired" do
    first, nested = create_list(:user, 2)
    start_member_impersonation(first)
    post "/linked_members/impersonations/#{nested.id}"
    allow_any_instance_of(ApplicationController).to receive(:impersonation_allowed?) do |_controller, context|
      context.target != nested
    end

    delete "/linked_members/impersonations/all"

    expect(response).to redirect_to("/")
    expect(request.session[Vouch::ImpersonationStack::SESSION_KEY]).to be_nil
    expect(status).to include("account" => account.id, "member" => nil, "admin" => membership.id)
  end

  it "does not swallow an application's unexpected permission exception" do
    start_member_impersonation(create(:user))
    allow_any_instance_of(ApplicationController).to receive(:impersonation_allowed?).and_raise(ArgumentError, "policy defect")

    expect { get "/linked_status" }.to raise_error(ArgumentError, "policy defect")
  end

  it "reports the actual preceding membership in the stop hook and response" do
    first, nested = create_list(:user, 2)
    start_member_impersonation(first)
    post "/linked_members/impersonations/#{nested.id}"
    restored = []
    LinkedMembers::ImpersonationsController.before_impersonation_end { |_target, previous| restored << previous.id }
    LinkedMembers::ImpersonationsController.define_method(:destroy) do
      super() { |result| render json: { restored: result.value.id } }
    end

    delete "/linked_members/impersonations"

    expect(response.parsed_body).to eq("restored" => first.id)
    expect(restored).to eq([first.id])
    expect(status).to include("member" => first.id)
  end

  it "lets full account impersonation manage only the effective account's MFA credentials" do
    target = create(:account)
    target_factor = target.two_factor_credentials.create!
    original_factor = account.two_factor_credentials.create!
    account_login
    get "/linked_admins/sign_in"
    post "/account_impersonations/#{target.id}"

    get "/linked_accounts/two_factor_credentials"
    expect(response.parsed_body).to eq("account" => target.id, "credentials" => [target_factor.id])
    delete "/linked_accounts/two_factor_credentials/#{target_factor.id}"
    expect(response).to redirect_to("/linked_accounts/two_factor_credentials")
    expect(TwoFactorCredential.exists?(target_factor.id)).to be(false)
    expect(TwoFactorCredential.exists?(original_factor.id)).to be(true)
    expect(status).to include("account" => target.id, "true_account" => account.id, "member" => nil)
  end

  it "links a provider only to the effective account during full account impersonation" do
    target = create(:account)
    account_login
    get "/linked_admins/sign_in"
    post "/account_impersonations/#{target.id}"
    auth = OmniAuth::AuthHash.new(provider: "github", uid: "impersonated-link", info: {email: "support@example.test"})

    oauth_callback "/linked_accounts/auth/github/callback", auth: auth, purpose: :link

    expect(response).to redirect_to("/")
    expect(target.omni_auth_identities.find_by(uid: "impersonated-link")).to be_present
    expect(account.omni_auth_identities.find_by(uid: "impersonated-link")).to be_nil
    expect(status).to include("account" => target.id, "true_account" => account.id)
    %i[sign_in register].each do |purpose|
      oauth_callback "/linked_accounts/auth/github/callback", auth: auth, purpose: purpose
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "denies provider linking during restricted membership impersonation" do
    target = create(:user)
    start_member_impersonation(target)
    auth = OmniAuth::AuthHash.new(provider: "github", uid: "restricted-link", info: {email: "support@example.test"})

    expect do
      oauth_callback "/linked_accounts/auth/github/callback", auth: auth, purpose: :link
    end.not_to change(OmniAuthIdentity, :count)
    expect(response).to have_http_status(:forbidden)
  end

  it "does not let a restricted membership impersonation escalate to an account" do
    target = create(:user)
    start_member_impersonation(target)
    post "/account_impersonations/#{target.account_id}"
    expect(response).to have_http_status(:forbidden)
    expect(status).to include("account" => account.id, "member" => target.id)
  end


end
