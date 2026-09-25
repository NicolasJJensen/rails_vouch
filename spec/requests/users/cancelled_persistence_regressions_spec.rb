# frozen_string_literal: true

require "rails_helper"
require "omniauth"

RSpec.describe "authentication writes cancelled by host callbacks", type: :request do
  it "does not publish sign-out state when its transactional hook rolls back" do
    user = create(:user)
    sign_in(user)
    original_hooks = Users::SessionsController.__hooks
    Users::SessionsController.after_sign_out { raise ActiveRecord::Rollback }

    delete "/users/sign_out"

    expect(response).to have_http_status(:forbidden)
    get "/users/two_factor_credentials"
    expect(response).to have_http_status(:ok)
  ensure
    Users::SessionsController.__hooks = original_hooks if original_hooks
  end

  it "does not publish a registration session when account creation rolls back" do
    callback = proc { raise ActiveRecord::Rollback }
    Account.set_callback(:create, :after, callback)
    counts = [Account.count, User.count, Organisation.count]

    post "/users/sign_up", params: {
      account: {
        email_address: "cancelled-signup@example.com",
        password: "new-password123",
        password_confirmation: "new-password123"
      }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect([Account.count, User.count, Organisation.count]).to eq(counts)
    get "/users/two_factor_credentials"
    expect(response).to redirect_to("/users/sign_in")
  ensure
    Account.skip_callback(:create, :after, callback) if callback
  end

  it "rolls back the account when OAuth identity creation is cancelled" do
    auth_hash = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "cancelled-provider-creation",
      info: { email: "cancelled-oauth@example.com", name: "Cancelled OAuth" }
    )
    callback = proc { raise ActiveRecord::Rollback }
    OmniAuthIdentity.set_callback(:create, :after, callback)
    counts = [Account.count, User.count, Organisation.count, OmniAuthIdentity.count]

    get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => auth_hash }

    expect(response).to redirect_to("/users/sign_in")
    expect([Account.count, User.count, Organisation.count, OmniAuthIdentity.count]).to eq(counts)
    get "/users/two_factor_credentials"
    expect(response).to redirect_to("/users/sign_in")
  ensure
    OmniAuthIdentity.skip_callback(:create, :after, callback) if callback
  end

  it "rolls back an OAuth link when its transactional lifecycle hook rolls back" do
    original_hooks = Users::OmniAuthsController.__hooks
    user = create(:user)
    sign_in(user)
    auth_hash = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "rolled-back-provider-link",
      info: { email: user.email_address, name: "Rolled Back Link" }
    )
    Users::OmniAuthsController.after_oauth_link { raise ActiveRecord::Rollback }

    get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => auth_hash }

    expect(response).to have_http_status(:forbidden)
    expect(OmniAuthIdentity.where(provider: "google_oauth2", uid: "rolled-back-provider-link")).not_to exist
  ensure
    Users::OmniAuthsController.__hooks = original_hooks if original_hooks
  end

  it "keeps the invitation proof and password when invitation acceptance is cancelled" do
    organisation = create(:organisation)
    invitation = create(
      :user,
      :invited,
      organisation: organisation,
      account: create(:account, registration_required: true),
      invitation_sent_at: 1.day.ago
    )
    original_digest = invitation.account.password_digest
    original_token = invitation.invitation_token
    callback = proc do
      raise ActiveRecord::Rollback if invitation_token_before_last_save.present? && invitation_token.nil?
    end
    User.set_callback(:update, :after, callback)

    get "/users/invitation/accept", params: { token: original_token }
    post "/users/sign_up", params: {
      account: {
        password: "replacement-password123",
        password_confirmation: "replacement-password123"
      }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(invitation.reload.invitation_token).to eq(original_token)
    expect(invitation.account.reload.password_digest).to eq(original_digest)
    expect(invitation.account).to be_registration_required
    get "/users/two_factor_credentials"
    expect(response).to redirect_to("/users/sign_in")
  ensure
    User.skip_callback(:update, :after, callback) if callback
  end

  it "does not publish acceptance when a signed-in invitation update is cancelled" do
    organisation = create(:organisation)
    account = create(:account)
    current_user = create(:user, account: account, organisation: organisation)
    invitation = create(
      :user,
      :invited,
      account: account,
      organisation: organisation,
      invitation_sent_at: 1.day.ago
    )
    original_token = invitation.invitation_token
    callback = proc do
      raise ActiveRecord::Rollback if invitation_token_before_last_save.present? && invitation_token.nil?
    end
    User.set_callback(:update, :after, callback)
    published = []
    original_hooks = Users::InvitationsController.__hooks
    Users::InvitationsController.after_commit_of_invitation_acceptance { published << :accepted }
    sign_in(current_user)

    get "/users/invitation/accept", params: { token: original_token }

    expect(response).to have_http_status(:unprocessable_content)
    expect(invitation.reload.invitation_token).to eq(original_token)
    expect(invitation.invitation_accepted_at).to be_nil
    expect(published).to be_empty
  ensure
    Users::InvitationsController.__hooks = original_hooks if original_hooks
    User.skip_callback(:update, :after, callback) if callback
  end

  it "rolls back the invited account and suppresses success when invitation creation is cancelled" do
    organisation = create(:organisation)
    inviter = create(:user, organisation: organisation)
    callback = proc { raise ActiveRecord::Rollback }
    User.set_callback(:create, :after, callback)
    published = []
    allow_any_instance_of(Users::InvitationsController).to receive(:run_hooks).and_wrap_original do |original, *args, **options, &block|
      published << args.first
      original.call(*args, **options, &block)
    end
    counts = [Account.count, User.count]
    sign_in(inviter)

    post "/users/invitation", params: { email_address: "cancelled-invite@example.com" }

    expect(response).to redirect_to("/")
    expect(flash[:notice]).to eq(I18n.t("vouch.invitations.sent"))
    expect([Account.count, User.count]).to eq(counts)
    expect(published).not_to include(:invitation_token_generation)
  ensure
    User.skip_callback(:create, :after, callback) if callback
  end

  it "does not publish a single-model invitation when its update is cancelled" do
    organisation = create(:organisation)
    target = create(:user, organisation: organisation)
    target.define_singleton_method(:registration_required?) { false }
    mapping = Vouch::Mapping.new(:user, model: "User")
    callback = proc { raise ActiveRecord::Rollback }
    User.set_callback(:update, :after, callback)
    published = []
    allow_any_instance_of(Users::InvitationsController).to receive(:auth_mapping).and_return(mapping)
    allow_any_instance_of(Users::InvitationsController).to receive(:build_invited_account).and_return(target)
    allow_any_instance_of(Users::InvitationsController).to receive(:run_hooks) do |_controller, name, *|
      published << name
    end
    sign_in(target)

    post "/users/invitation", params: { email_address: target.email_address }

    expect(response).to redirect_to("/")
    expect(target.reload.invitation_token).to be_nil
    expect(published).not_to include(:invitation_token_generation)
  ensure
    User.skip_callback(:update, :after, callback) if callback
  end

  it "preserves a revocable invitation when destruction is cancelled" do
    organisation = create(:organisation)
    inviter = create(:user, organisation: organisation)
    invitation = create(:user, :invited, organisation: organisation, inviter: inviter)
    token = invitation.invitation_token
    callback = proc { raise ActiveRecord::Rollback }
    User.set_callback(:destroy, :after, callback)
    sign_in(inviter)

    delete "/users/invitation", params: { invitation_token: token }

    expect(response).to have_http_status(:unprocessable_content)
    expect(invitation.reload.invitation_token).to eq(token)
    expect(flash[:notice]).not_to eq(I18n.t("vouch.invitations.revoked"))
  ensure
    User.skip_callback(:destroy, :after, callback) if callback
  end
end
