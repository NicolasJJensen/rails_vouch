require "rails_helper"

RSpec.describe "Invitation acceptance choices", type: :request do
  let(:organisation) { create(:organisation) }
  let(:placeholder) { create(:account, registration_required: true) }
  let(:invitation) { create(:user, :invited, account: placeholder, organisation: organisation) }

  it "shows choices without changing the invitation or registration context" do
    token = invitation.invitation_token
    get "/users/invitation/accept", params: {token: token}
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Sign in to an existing account", "Register a new account", "Reject invitation")
    expect(invitation.reload.invitation_token).to eq(token)
    get "/users/sign_up"
    expect(response.body).not_to include(placeholder.email_address)
  end

  it "completes a new account only after the explicit registration choice" do
    post "/users/invitation/accept", params: {token: invitation.invitation_token, choice: "new"}
    expect(response).to redirect_to("/users/sign_up")
    post "/users/sign_up", params: {account: {password: "chosen-password", password_confirmation: "chosen-password"}}
    expect(invitation.reload.invitation_accepted_at).to be_present
    expect(invitation.account).to eq(placeholder)
  end

  it "links a pending membership to the explicitly chosen signed-in account" do
    operator = create(:user)
    sign_in(operator)
    original_owner = invitation.account
    post "/users/invitation/accept", params: {token: invitation.invitation_token, choice: "current"}
    expect(invitation.reload.account).to eq(operator.account)
    expect(invitation.invitation_accepted_at).to be_present
    expect(invitation.organisation).to eq(organisation)
    expect(Account.exists?(original_owner.id)).to be true
  end

  it "links after an existing account signs in and does not create another account" do
    existing = create(:account)
    post "/users/invitation/accept", params: {token: invitation.invitation_token, choice: "existing"}
    expect(response).to redirect_to("/users/sign_in")
    expect {
      post "/users/sign_in", params: {email_address: existing.email_address, password: "password123"}
    }.not_to change(Account, :count)
    expect(invitation.reload.account).to eq(existing)
    expect(invitation.invitation_accepted_at).to be_present
  end

  it "cannot move a registered account's membership to another account" do
    invitation.account.update!(registration_required: false)
    operator = create(:user)
    sign_in(operator)
    post "/users/invitation/accept", params: {token: invitation.invitation_token, choice: "current"}
    expect(invitation.reload.account).to eq(placeholder)
    expect(invitation.invitation_accepted_at).to be_nil
  end

  it "rejects explicitly without deleting the account or admitting the membership" do
    token = invitation.invitation_token
    post "/users/invitation/reject", params: {token: token}
    expect(invitation.reload.invitation_rejected_at).to be_present
    expect(invitation.invitation_token).to be_nil
    expect(Account.exists?(placeholder.id)).to be true
    post "/users/invitation/reject", params: {token: token}
    expect(response).to redirect_to("/users/sign_in")
  end
  it "does not reassign a pending membership until the chosen account completes MFA" do
    existing = create(:account)
    factor = existing.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    existing.enable_two_factor!
    post "/users/invitation/accept", params: {token: invitation.invitation_token, choice: "existing"}
    post "/users/sign_in", params: {email_address: existing.email_address, password: "password123"}
    expect(response).to redirect_to("/users/two_factor_challenges")
    expect(invitation.reload.account).to eq(placeholder)
    get "/users/two_factor_challenges/#{factor.id}"
    patch "/users/two_factor_challenges/#{factor.id}", params: {code: ROTP::TOTP.new(factor.otp_secret).now}
    expect(invitation.reload.account).to eq(existing)
    expect(invitation.invitation_accepted_at).to be_present
  end

  it "can issue a new invitation after recipient rejection" do
    operator = create(:user, organisation: organisation)
    email = invitation.account.email_address
    post "/users/invitation/reject", params: {token: invitation.invitation_token}
    sign_in(operator)
    expect {
      post "/users/invitation", params: {email_address: email}
    }.not_to change(User, :count)
    expect(invitation.reload.invitation_rejected_at).to be_nil
    expect(invitation.invitation_token).to be_present
  end

  it "rolls rejection back when its lifecycle is cancelled" do
    original = Users::InvitationsController.__hooks
    Users::InvitationsController.after_invitation_rejection { raise ActiveRecord::Rollback }
    token = invitation.invitation_token
    post "/users/invitation/reject", params: {token: token}
    expect(invitation.reload.invitation_token).to eq(token)
    expect(invitation.invitation_rejected_at).to be_nil
  ensure
    Users::InvitationsController.__hooks = original if original
  end

  it "rejects an invitation reassigned to another pending owner during sign-in" do
    destination = create(:account)
    factor = destination.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    destination.enable_two_factor!
    post "/users/invitation/accept", params: {token: invitation.invitation_token, choice: "existing"}
    post "/users/sign_in", params: {email_address: destination.email_address, password: "password123"}
    replacement = create(:account, registration_required: true)
    invitation.update!(account: replacement)
    get "/users/two_factor_challenges/#{factor.id}"
    patch "/users/two_factor_challenges/#{factor.id}", params: {code: ROTP::TOTP.new(factor.otp_secret).now}
    expect(invitation.reload.account).to eq(replacement)
    expect(invitation.invitation_accepted_at).to be_nil
  end

  it "does not link an invitation while impersonating only a membership" do
    operator = create(:user)
    target = create(:user)
    sign_in(operator)
    post "/users/impersonations/#{target.id}"
    expect(response).to redirect_to("/")
    token = invitation.invitation_token
    post "/users/invitation/accept", params: {token: token, choice: "current"}
    expect(response).to have_http_status(:forbidden)
    expect(invitation.reload.account).to eq(placeholder)
    expect(invitation.invitation_token).to eq(token)
  end

end
