# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Linked invitation and impersonation flows", type: :request do
  let(:organisation) { create(:organisation) }
  let(:operator_account) do
    create(:account, email_address: "operator@example.com", password: "password123", password_confirmation: "password123")
  end
  let!(:operator) { create(:user, account: operator_account, organisation: organisation) }

  before do
    @original_mappings = Vouch.mappings.dup
    stub_const("LinkedOptional", Module.new)
    stub_const("LinkedOptional::AccountsController", Class.new(ApplicationController))
    stub_const("LinkedOptional::AccountSessionsController", Class.new(Vouch::SessionsController) do
      auth_scope :account
    end)
    stub_const("LinkedOptional::AccountRegistrationsController", Class.new(Vouch::RegistrationsController) do
      auth_scope :account
    end)
    stub_const("LinkedOptional::MemberSessionsController", Class.new(Vouch::MembershipSessionsController) do
      auth_scope :member
    end)
    stub_const("LinkedOptional::MemberInvitationsController", Class.new(Vouch::InvitationsController) do
      auth_scope :member

      private

      def authorize_invitation!
        true
      end
    end)
    stub_const("LinkedOptional::MemberImpersonationsController", Class.new(Vouch::ImpersonationsController) do
      auth_scope :member

      private

      def authorize_impersonation!
        true
      end
    end)
    stub_const("LinkedOptional::StatusController", Class.new(ApplicationController) do
      def show
        render json: {
          account: current_account&.id,
          member: current_account_member&.id,
          current_member: current_member&.id
        }
      end
    end)

    Rails.application.routes.draw do
      Vouch.routes(self) do |auth|
        auth.scope :account, model: "Account", path: "linked_accounts" do
          auth.sessions controller: "linked_optional/account_sessions"
          auth.registrations controller: "linked_optional/account_registrations"
        end
        auth.scope :member, account_scope: :account, identity: "User", tenant: "Organisation", path: "linked_members" do
          auth.sessions controller: "linked_optional/member_sessions"
          auth.invitations controller: "linked_optional/member_invitations"
          auth.impersonation controller: "linked_optional/member_impersonations"
        end
      end
      get "/linked_status", to: "linked_optional/status#show"
      root "rails/health#show"
    end
  end

  after do
    Vouch.mappings.replace(@original_mappings)
    Vouch::ApplicationHelpers.refresh!
    Rails.application.reload_routes!
  end

  def account_login(account = operator_account)
    post "/linked_accounts/sign_in", params: { email_address: account.email_address, password: "password123" }
  end

  def member_login
    get "/linked_members/sign_in"
  end

  def status
    get "/linked_status"
    response.parsed_body
  end

  it "carries a member invitation through parent account registration" do
    invited_account = create(:account, registration_required: true)
    invitee = create(:user, :invited, account: invited_account, organisation: organisation,
      inviter: operator)

    get "/linked_members/invitation/accept", params: { token: invitee.invitation_token }
    expect(response).to redirect_to("/linked_accounts/sign_up")

    post "/linked_accounts/sign_up", params: {
      account: { password: "new-password123", password_confirmation: "new-password123" }
    }
    expect(response).to redirect_to("/linked_members/sign_in")

    member_login
    expect(response).to redirect_to("/")
    expect(status).to include("account" => invited_account.id, "member" => invitee.id, "current_member" => invitee.id)
  end

  it "retains the operator account while switching and restoring the membership" do
    target_account = create(:account, email_address: "target@example.com", password: "password123", password_confirmation: "password123")
    target = create(:user, account: target_account, organisation: organisation)

    account_login
    member_login
    expect(status).to include("account" => operator_account.id, "member" => operator.id)

    post "/linked_members/impersonations/#{target.id}"
    expect(response).to redirect_to("/")
    expect(status).to include("account" => operator_account.id, "member" => target.id, "current_member" => target.id)

    member_login
    expect(response).to have_http_status(:forbidden)
    expect(status).to include("account" => operator_account.id, "member" => target.id)
    delete "/linked_members/impersonations"
    expect(response).to redirect_to("/")
    expect(status).to include("account" => operator_account.id, "member" => operator.id, "current_member" => operator.id)
  end

  it "does not leave the target parent session after member sign-out during impersonation" do
    target_account = create(:account, email_address: "target-signout@example.com", password: "password123", password_confirmation: "password123")
    target = create(:user, account: target_account, organisation: organisation)

    account_login
    member_login
    post "/linked_members/impersonations/#{target.id}"
    delete "/linked_members/sign_out"

    expect(status).to include("account" => nil, "member" => nil, "current_member" => nil)
  end

  it "accepts an existing-account invitation after parent authentication" do
    invited_account = create(:account)
    invitee = create(:user, :invited, account: invited_account, organisation: organisation,
      inviter: operator)

    account_login(invited_account)
    get "/linked_members/invitation/accept", params: { token: invitee.invitation_token }
    expect(response).to redirect_to("/linked_members/sign_in")

    member_login
    expect(response).to redirect_to("/")
    expect(invitee.reload.invitation_token).to be_nil
    expect(status).to include("account" => invited_account.id, "member" => invitee.id, "current_member" => invitee.id)
  end

  it "does not consume an invitation for a different authenticated parent" do
    invited_account = create(:account)
    invitee = create(:user, :invited, account: invited_account, organisation: organisation,
      inviter: operator)

    account_login
    get "/linked_members/invitation/accept", params: { token: invitee.invitation_token }
    expect(response).to redirect_to("/linked_members/sign_in")

    member_login
    expect(response).to redirect_to("/")
    expect(invitee.reload.invitation_token).to be_present
    expect(status).to include("account" => operator_account.id, "member" => operator.id)
  end
end
