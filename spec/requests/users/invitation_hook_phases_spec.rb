# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Invitation acceptance hook phases", type: :request do
  let(:account) { create(:account) }
  let(:invitation) { create(:user, :invited, account: account) }

  def observe_acceptance(controller)
    original = controller.__hooks
    observations = []
    controller.before_commit_of_invitation_acceptance do |identity, _account|
      observations << [:before_commit, ActiveRecord::Base.connection.open_transactions, identity.reload.invitation_token.present?]
    end
    controller.before_invitation_acceptance do |identity, _account|
      observations << [:before, ActiveRecord::Base.connection.open_transactions, identity.reload.invitation_token.present?]
    end
    controller.after_invitation_acceptance do |identity, _account|
      observations << [:after, ActiveRecord::Base.connection.open_transactions, identity.reload.invitation_token.present?]
    end
    controller.after_commit_of_invitation_acceptance do |identity, _account|
      observations << [:after_commit, ActiveRecord::Base.connection.open_transactions, identity.reload.invitation_token.present?]
      observations << [:authenticated, current_identity.present?]
    end
    yield
    observations
  ensure
    controller.__hooks = original
  end

  def expect_acceptance_order(observations, outer_transactions)
    expect(observations.map(&:first)).to eq([:before_commit, :before, :after, :after_commit, :authenticated])
    expect(observations[0]).to eq([:before_commit, outer_transactions, true])
    expect(observations[1][1]).to be > outer_transactions
    expect(observations[1][2]).to be(true)
    expect(observations[2][1]).to be > outer_transactions
    expect(observations[2][2]).to be(false)
    expect(observations[3]).to eq([:after_commit, outer_transactions, false])
    expect(observations[4]).to eq([:authenticated, true])
  end

  it "runs each phase once around acceptance by an already signed-in account" do
    sign_in(create(:user, account: account))
    invitation
    depth = ActiveRecord::Base.connection.open_transactions
    observations = observe_acceptance(Users::InvitationsController) do
      get "/users/invitation/accept", params: {token: invitation.invitation_token}
    end

    expect(response).to redirect_to("/")
    expect_acceptance_order(observations, depth)
  end

  it "wraps sign-in acceptance with commit callbacks outside its transaction" do
    get "/users/invitation/accept", params: {token: invitation.invitation_token}
    depth = ActiveRecord::Base.connection.open_transactions
    observations = observe_acceptance(Users::SessionsController) do
      post "/users/sign_in", params: {email_address: account.email_address, password: "password123"}
    end

    expect(response).to redirect_to("/")
    expect_acceptance_order(observations, depth)
  end

  it "wraps invited registration and its accompanying database work" do
    account.update!(registration_required: true)
    get "/users/invitation/accept", params: {token: invitation.invitation_token}
    depth = ActiveRecord::Base.connection.open_transactions
    observations = observe_acceptance(Users::RegistrationsController) do
      post "/users/sign_up", params: {account: {password: "replacement123", password_confirmation: "replacement123"}}
    end

    expect(response).to redirect_to("/")
    expect_acceptance_order(observations, depth)
  end

  it "can cancel invited registration before its transaction starts" do
    account.update!(registration_required: true)
    digest = account.password_digest
    token = invitation.invitation_token
    get "/users/invitation/accept", params: {token: token}
    original = Users::RegistrationsController.__hooks
    Users::RegistrationsController.before_commit_of_invitation_acceptance { throw :abort }

    post "/users/sign_up", params: {account: {password: "replacement123", password_confirmation: "replacement123"}}

    expect(response).to have_http_status(:forbidden)
    expect(account.reload.password_digest).to eq(digest)
    expect(invitation.reload.invitation_token).to eq(token)
  ensure
    Users::RegistrationsController.__hooks = original if original
  end
end
