# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::Invitable::Concern do
  let(:organisation) { create(:organisation) }
  let(:inviter) { create(:user, organisation: organisation) }

  describe ".invite!" do
    it "creates a user with an invitation token" do
      invitee = User.invite!(invited_by: inviter) do |u|
        u.organisation = organisation
        u.account = create(:account, email_address: "new@example.com")
      end
      invitee = invitee.value
      expect(invitee).to be_persisted
      expect(invitee.invitation_token).to be_present
    end

    it "sets invitation_sent_at" do
      invitee = User.invite!(invited_by: inviter) do |u|
        u.organisation = organisation
        u.account = create(:account, email_address: "sent@example.com")
      end
      expect(invitee.value.invitation_sent_at).to be_present
    end

    it "sets the inviter" do
      invitee = User.invite!(invited_by: inviter) do |u|
        u.organisation = organisation
        u.account = create(:account, email_address: "inv@example.com")
      end
      expect(invitee.value.inviter).to eq(inviter)
    end

    it "yields the invitee for customization" do
      yielded = nil
      User.invite!(invited_by: inviter) do |u|
        yielded = u
        u.organisation = organisation
        u.account = create(:account, email_address: "yield@example.com")
      end
      expect(yielded).to be_a(User)
    end

    it "generates a UUID token" do
      invitee = User.invite! do |u|
        u.organisation = organisation
        u.account = create(:account, email_address: "uuid@example.com")
      end
      expect(invitee.value.invitation_token).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end

    it "rolls back side effects from its block when creation is cancelled" do
      callback = proc { raise ActiveRecord::Rollback }
      User.set_callback(:create, :after, callback)
      account_count = Account.count

      expect {
        User.invite! do |invitee|
          invitee.organisation = organisation
          invitee.account = Account.create!(email_address: "cancelled-standalone-invite@example.com", password: "password123")
        end
      }.to raise_error(Vouch::Persistence::Cancelled)
      expect(Account.count).to eq(account_count)
    ensure
      User.skip_callback(:create, :after, callback) if callback
    end
  end

  describe "#invitation_expired?" do
    it "returns false within the expiry window" do
      user = create(:user, :invited, organisation: organisation, invitation_sent_at: 1.day.ago)
      expect(user.invitation_expired?).to be false
    end

    it "returns true after the expiry window (7 days)" do
      user = create(:user, :invited, organisation: organisation, invitation_sent_at: 8.days.ago)
      expect(user.invitation_expired?).to be true
    end

    it "returns true when invitation_sent_at is blank" do
      user = create(:user, :invited, organisation: organisation, invitation_sent_at: nil)
      expect(user.invitation_expired?).to be true
    end
  end

  describe "#accept_invitation!" do
    let(:user) { create(:user, :invited, organisation: organisation, invitation_sent_at: 1.day.ago) }

    it "clears the invitation token" do
      user.accept_invitation!
      expect(user.reload.invitation_token).to be_nil
    end

    it "clears invitation_sent_at" do
      user.accept_invitation!
      expect(user.reload.invitation_sent_at).to be_nil
    end

    it "sets invitation_accepted_at" do
      user.accept_invitation!
      expect(user.reload.invitation_accepted_at).to be_present
    end

    it "rejects acceptance from an instance loaded before the invitation was accepted" do
      stale_user = User.find(user.id)
      user.accept_invitation!
      accepted_at = user.reload.invitation_accepted_at

      expect { stale_user.accept_invitation! }
        .to raise_error(Vouch::Invitable::InvitationExpiredError)
      expect(user.reload.invitation_accepted_at).to eq(accepted_at)
    end

    it "rejects acceptance from an instance loaded before the invitation was revoked" do
      stale_user = User.find(user.id)
      user.update_columns(invitation_token: nil, invitation_sent_at: nil)

      expect { stale_user.accept_invitation! }
        .to raise_error(Vouch::Invitable::InvitationExpiredError)
      expect(user.reload.invitation_accepted_at).to be_nil
    end

    it "rejects acceptance from an instance loaded before the invitation expired" do
      stale_user = User.find(user.id)
      user.update_columns(invitation_sent_at: 8.days.ago)

      expect { stale_user.accept_invitation! }
        .to raise_error(Vouch::Invitable::InvitationExpiredError)
      expect(user.reload.invitation_token).to be_present
    end

    it "does not consume a reissued invitation through an instance holding the old token" do
      stale_user = User.find(user.id)
      reissued_token = SecureRandom.uuid
      user.update_columns(invitation_token: reissued_token, invitation_sent_at: Time.current)

      expect { stale_user.accept_invitation! }
        .to raise_error(Vouch::Invitable::InvitationExpiredError)
      expect(user.reload.invitation_token).to eq(reissued_token)
      expect(user.invitation_accepted_at).to be_nil
    end

    it "rolls back callback side effects when acceptance is cancelled" do
      before_update = proc { Organisation.create!(name: "cancelled acceptance side effect") }
      after_update = proc { raise ActiveRecord::Rollback }
      User.set_callback(:update, :before, before_update)
      User.set_callback(:update, :after, after_update)
      token = user.invitation_token
      organisation_count = Organisation.count

      expect { user.accept_invitation! }
        .to raise_error(Vouch::Persistence::Cancelled)
      expect(Organisation.count).to eq(organisation_count)
      expect(user.reload.invitation_token).to eq(token)
    ensure
      User.skip_callback(:update, :before, before_update) if before_update
      User.skip_callback(:update, :after, after_update) if after_update
    end
  end

  describe ".find_by_invitation_token" do
    it "finds a user by token" do
      user = create(:user, :invited, organisation: organisation)
      found = User.find_by_invitation_token(user.invitation_token)
      expect(found).to eq(user)
    end

    it "returns nil for non-existent token" do
      expect(User.find_by_invitation_token("nonexistent")).to be_nil
    end
  end

  describe ".pending_invitation" do
    it "returns users with invitation tokens" do
      pending_user = create(:user, :invited, organisation: organisation)
      _accepted_user = create(:user, organisation: organisation)

      expect(User.pending_invitation).to include(pending_user)
      expect(User.pending_invitation).not_to include(_accepted_user)
    end
  end

  describe "associations" do
    it "belongs_to :inviter" do
      invitee = create(:user, organisation: organisation, inviter: inviter)
      expect(invitee.inviter).to eq(inviter)
    end

    it "has_many :invitees" do
      invitee = create(:user, organisation: organisation, inviter: inviter)
      expect(inviter.invitees).to include(invitee)
    end

    it "nullifies invitees when inviter is destroyed" do
      invitee = create(:user, organisation: organisation, inviter: inviter)
      inviter.destroy
      expect(invitee.reload.inviter_id).to be_nil
    end
  end
end
