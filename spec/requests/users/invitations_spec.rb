# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Users::Invitations", type: :request do
  let(:organisation) { create(:organisation) }
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, organisation: organisation) }

  describe "GET /users/invitation/accept" do
    it "redirects with alert for invalid token" do
      get "/users/invitation/accept", params: { token: "invalid" }
      expect(response).to redirect_to("/users/sign_in")
    end

    it "redirects with alert for expired token" do
      invitee = create(:user, :invited, organisation: organisation, invitation_sent_at: 8.days.ago)
      get "/users/invitation/accept", params: { token: invitee.invitation_token }
      expect(response).to redirect_to("/users/sign_in")
    end

    it "redirects to registration for valid token" do
      invitee = create(:user, :invited, organisation: organisation, invitation_sent_at: 1.day.ago, invitation_registration_required: true, inviter: user)
      get "/users/invitation/accept", params: { token: invitee.invitation_token }
      expect(response).to redirect_to("/users/sign_up")
    end
  end

  describe "POST /users/invitation" do
    it "requires authentication" do
      post "/users/invitation", params: { email_address: "test@example.com" }
      expect(response).to redirect_to("/users/sign_in")
    end

    it "raises until the host configures invitation authorization" do
      sign_in(user)
      allow_any_instance_of(Users::InvitationsController).to receive(:authorize_invitation!) do |controller|
        Vouch::InvitationsController.instance_method(:authorize_invitation!).bind_call(controller)
      end

      expect {
        post "/users/invitation", params: {email_address: "newinvite@example.com"}
      }.to raise_error(Vouch::ConfigurationError, /authorize_invitation!/)
    end

    it "does not create an invitation when the host denies authorization" do
      sign_in(user)
      allow_any_instance_of(Users::InvitationsController).to receive(:authorize_invitation!) { |controller|
        controller.head :forbidden
      }

      expect {
        post "/users/invitation", params: {email_address: "newinvite@example.com"}
      }.not_to change(User, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it "creates an invitation when authenticated" do
      sign_in(user)

      expect {
        post "/users/invitation", params: { email_address: "newinvite@example.com" }
      }.to change(User, :count).by(1)
        .and change(Account, :count).by(1)

      expect(response).to redirect_to("/")

      invitee = User.order(:id).last
      expect(invitee.invitation_token).to be_present
      expect(invitee.inviter).to eq(user)
      expect(invitee.organisation).to eq(organisation)
    end

    it "shows the same success message even when invitation fails" do
      sign_in(user)
      allow(User).to receive(:invite!).and_raise(ActiveRecord::RecordInvalid)

      post "/users/invitation", params: { email_address: "bad@example.com" }
      expect(response).to redirect_to("/")
      expect(flash[:notice]).to eq(I18n.t("vouch.invitations.sent"))
    end
  end

  describe "DELETE /users/invitation" do
    it "requires authentication" do
      delete "/users/invitation", params: { invitation_token: "some-token" }
      expect(response).to redirect_to("/users/sign_in")
    end

    it "revokes an invitation when authenticated" do
      sign_in(user)
      invitee = create(:user, :invited, organisation: organisation, invitation_sent_at: 1.day.ago, invitation_registration_required: true, inviter: user)

      expect {
        delete "/users/invitation", params: { invitation_token: invitee.invitation_token }
      }.to change(User, :count).by(-1)

      expect(response).to redirect_to("/")
    end
  end
  describe "placeholder account lifecycle" do
    def invite(email = "pending@example.com")
      sign_in(user)
      post "/users/invitation", params: { email_address: email }
      expect(response).to redirect_to("/")
      User.order(:id).last
    end

    it "removes an unused placeholder and permits reinvitation and registration" do
      invitation = invite
      placeholder_id = invitation.account_id
      delete "/users/invitation", params: { invitation_token: invitation.invitation_token }
      expect(Account.exists?(placeholder_id)).to be true

      replacement = invite
      logout(:user)
      get "/users/invitation/accept", params: { token: replacement.invitation_token }
      expect(response).to redirect_to("/users/sign_up")
      post "/users/sign_up", params: { account: { password: "chosen-password123", password_confirmation: "chosen-password123" } }
      expect(replacement.reload.invitation_accepted_at).to be_present
      expect(replacement.account.reload.authenticate("chosen-password123")).to be_truthy
    end

    it "requires registration for a second invitation to the same placeholder" do
      first = invite
      second = invite
      expect(second.account_id).to eq(first.account_id)
      logout(:user)
      get "/users/invitation/accept", params: { token: second.invitation_token }
      expect(response).to redirect_to("/users/sign_up")
    end

    it "retains a placeholder while another invitation references it" do
      first = invite
      second = invite
      delete "/users/invitation", params: { invitation_token: first.invitation_token }
      expect(Account.exists?(second.account_id)).to be true
      expect(second.reload.invitation_token).to be_present
      delete "/users/invitation", params: { invitation_token: second.invitation_token }
      expect(Account.exists?(second.account_id)).to be true
    end

    it "retains an account with another active identity" do
      invitation = invite
      active = create(:user, account: invitation.account)
      delete "/users/invitation", params: { invitation_token: invitation.invitation_token }
      expect(Account.exists?(active.account_id)).to be true
      expect(User.exists?(active.id)).to be true
    end

    it "retains a registered account after revoking its invitation" do
      existing = create(:account)
      invitation = invite(existing.email_address)
      delete "/users/invitation", params: { invitation_token: invitation.invitation_token }
      expect(Account.exists?(existing.id)).to be true
    end

    it "uses sign-in for remaining invitations after registration and rejects a pending signup form" do
      first = invite
      second = invite
      logout(:user)
      other_browser = ActionDispatch::Integration::Session.new(Rails.application)
      other_browser.host! "www.example.com"
      other_browser.get "/users/invitation/accept", params: { token: second.invitation_token }
      expect(other_browser.response.location).to eq("http://www.example.com/users/sign_up")

      logout(:user)
      get "/users/invitation/accept", params: { token: first.invitation_token }
      post "/users/sign_up", params: { account: { password: "first-password123", password_confirmation: "first-password123" } }
      expect(first.reload.invitation_accepted_at).to be_present
      other_browser.post "/users/sign_up", params: { account: { password: "replacement-password123", password_confirmation: "replacement-password123" } }
      expect(other_browser.response.location).to eq("http://www.example.com/users/sign_in")
      expect(first.account.reload.authenticate("first-password123")).to be_truthy
      other_browser.get "/users/invitation/accept", params: { token: second.invitation_token }
      expect(other_browser.response.location).to eq("http://www.example.com/users/sign_in")
      other_browser.post "/users/sign_in", params: { email_address: first.account.email_address, password: "first-password123" }
      other_browser.post "/users/select", params: { identity_id: second.id }
      expect(second.reload.invitation_accepted_at).to be_present
    end

    it "revokes the invitation without invoking host account destruction" do
      invitation = invite
      delete "/users/invitation", params: { invitation_token: invitation.invitation_token }
      expect(response).to redirect_to("/")
      expect(User.exists?(invitation.id)).to be false
      expect(Account.exists?(invitation.account_id)).to be true
    end

    it "retains an unused placeholder by default" do
      invitation = invite
      delete "/users/invitation", params: { invitation_token: invitation.invitation_token }
      expect(User.exists?(invitation.id)).to be false
      expect(Account.exists?(invitation.account_id)).to be true
      replacement = invite
      expect(replacement.account_id).to eq(invitation.account_id)
      expect(replacement.invitation_registration_required?).to be true
    end

    it "allows a host around hook to remove a disposable placeholder atomically" do
      invitation = invite
      original_hooks = Users::InvitationsController.__hooks
      Users::InvitationsController.around_commit_of_invitation_revocation do |operation, _invitation, account|
        operation.call
        account.destroy!
      end

      delete "/users/invitation", params: { invitation_token: invitation.invitation_token }
      expect(response).to redirect_to("/")
      expect(Account.exists?(invitation.account_id)).to be false
    ensure
      Users::InvitationsController.__hooks = original_hooks if original_hooks
    end

    it "rolls back invitation revocation when host cleanup is cancelled" do
      invitation = invite
      callback = -> { throw :abort }
      Account.set_callback(:destroy, :before, callback)
      original_hooks = Users::InvitationsController.__hooks
      Users::InvitationsController.around_commit_of_invitation_revocation do |operation, _invitation, account|
        operation.call
        account.destroy!
      end

      delete "/users/invitation", params: { invitation_token: invitation.invitation_token }
      expect(response).to have_http_status(:unprocessable_content)
      expect(User.exists?(invitation.id)).to be true
      expect(Account.exists?(invitation.account_id)).to be true
    ensure
      Account.skip_callback(:destroy, :before, callback) if callback
      Users::InvitationsController.__hooks = original_hooks if original_hooks
    end

    it "retains a placeholder with an identity in another registered mapping" do
      invitation = invite
      account = invitation.account
      account.omni_auth_identities.create!(provider: "other", uid: "pending", auth_data: "{}")
      other_mapping = Vouch::Mapping.new(:other, account: "Account", identity: "OmniAuthIdentity",
        associations: {account_identities: :omni_auth_identities})
      mappings = Vouch.each_mapping.to_a + [other_mapping]
      allow(Vouch).to receive(:each_mapping).and_return(mappings.each)

      delete "/users/invitation", params: { invitation_token: invitation.invitation_token }
      expect(User.exists?(invitation.id)).to be false
      expect(Account.exists?(account.id)).to be true
      expect(account.omni_auth_identities.count).to eq(1)
    end

    it "clears rejected invitation state so ordinary registration can proceed" do
      invitation = invite
      logout(:user)
      get "/users/invitation/accept", params: { token: invitation.invitation_token }
      invitation.account.complete_registration!
      post "/users/sign_up", params: { account: { password: "unused-password123", password_confirmation: "unused-password123" } }
      expect(response).to redirect_to("/users/sign_in")

      expect {
        post "/users/sign_up", params: { account: { email_address: "separate@example.com", password: "separate-password123", password_confirmation: "separate-password123" } }
      }.to change(Account, :count).by(1)
    end
  end

end
