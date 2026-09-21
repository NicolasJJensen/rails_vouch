# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::ControllerHelpers do
  let(:controller_class) do
    Class.new(ApplicationController) do
      include Vouch::ControllerHelpers
      auth_scope :user
    end
  end

  let(:controller) { controller_class.new }
  let(:session) { {} }
  before { allow(controller).to receive(:session).and_return(session) }

  # Force route loading so the real :user mapping exists before we swap it.
  # Without this, Vouch.mappings[:user] is nil at boot (lazy-loaded),
  # and restoring nil in `after` corrupts global state for subsequent specs.
  before do
    Rails.application.routes.routes # triggers route loading
    @original_mapping = Vouch.mappings[:user]
  end

  after do
    Vouch.mappings[:user] = @original_mapping
  end

  describe "#build_registration" do
    it "keeps onboarding extension points private on the controller facade" do
      expect(controller.private_methods).to include(
        :build_registration,
        :registration_tenant_attributes,
        :accept_pending_invitation,
        :build_invited_identity
      )
      expect(controller.public_methods).not_to include(
        :build_registration,
        :registration_tenant_attributes,
        :accept_pending_invitation,
        :build_invited_identity
      )
    end

    context "with a tenant mapping" do
      before do
        mapping = Vouch::Mapping.new(
          :user, account: "Account", identity: "User", tenant: "Organisation"
        )
        mapping.resolve_reflections!
        Vouch.mappings[:user] = mapping
      end

      it "creates a tenant and identity via reflection" do
        # Override registration_tenant_attributes on this test controller
        controller.define_singleton_method(:registration_tenant_attributes) do |account|
          { name: "#{account.email_address}'s Organisation" }
        end

        account = create(:account)
        user = controller.send(:build_registration, account)

        expect(user).to be_a(User)
        expect(user).to be_persisted
        expect(user.account).to eq(account)
        expect(user.organisation).to be_present
        expect(user.organisation.name).to include(account.email_address)
      end
    end

    context "with a split-model mapping (no tenant)" do
      before do
        mapping = Vouch::Mapping.new(
          :user, account: "Account", identity: "User"
        )
        mapping.resolve_reflections!
        Vouch.mappings[:user] = mapping
      end

      it "attempts to create an identity directly" do
        account = create(:account)

        # In the dummy app, User requires an organisation (belongs_to with NOT NULL).
        # A real no-tenant app wouldn't have this constraint.
        # This verifies the code path tries Identity.create!(account:) without a tenant.
        expect {
          controller.send(:build_registration, account)
        }.to raise_error(ActiveRecord::RecordInvalid, /Organisation must exist/)
      end
    end

    context "with a single-model mapping" do
      before do
        mapping = Vouch::Mapping.new(
          :user, model: "Account"
        )
        mapping.resolve_reflections!
        Vouch.mappings[:user] = mapping
      end

      it "returns the account itself" do
        account = create(:account)
        result = controller.send(:build_registration, account)

        expect(result).to eq(account)
      end
    end
  end

  describe "OAuth continuation serialization" do
    it "keeps only provider, uid, and compact default profile metadata" do
      auth_hash = OmniAuth::AuthHash.new(provider: "google", uid: "123",
        info: {email: "member@example.com", name: "Member", image: "https://example.test/image", bio: "x" * 5_000})

      payload = controller.send(:serialize_oauth, auth_hash)

      expect(payload).to eq(
        "provider" => "google", "uid" => "123",
        "info" => {"email" => "member@example.com", "name" => "Member", "image" => "https://example.test/image"}
      )
      expect(controller.send(:parse_oauth, payload)).to be_a(OmniAuth::AuthHash)
    end

    it "allows a host controller to override the continuation payload" do
      controller.define_singleton_method(:serialize_oauth) { |_auth| {"provider" => "host", "uid" => "opaque"} }
      controller.define_singleton_method(:parse_oauth) { |payload| OmniAuth::AuthHash.new(payload.merge("info" => {"source" => "host"})) }

      payload = controller.send(:serialize_oauth, OmniAuth::AuthHash.new(provider: "google", uid: "123"))
      expect(controller.send(:parse_oauth, payload).info.source).to eq("host")
    end
  end

  describe "#assign_tenant_to_invitee" do
    before do
      mapping = Vouch::Mapping.new(
        :user, account: "Account", identity: "User", tenant: "Organisation"
      )
      mapping.resolve_reflections!
      Vouch.mappings[:user] = mapping
    end

    it "copies the tenant from inviter to invitee" do
      org = create(:organisation)
      inviter = create(:user, organisation: org)
      invitee = User.new

      controller.send(:assign_tenant_to_invitee, invitee, inviter)

      expect(invitee.organisation).to eq(org)
    end
  end

  describe "#registration_tenant_attributes" do
    it "raises NotImplementedError by default" do
      account = create(:account)

      expect {
        controller.send(:registration_tenant_attributes, account)
      }.to raise_error(NotImplementedError, /must define #registration_tenant_attributes/)
    end
  end

  describe "#build_invited_account" do
    it "dispatches to the host build_invited_identity override" do
      identity = double("invited account")
      expect(controller).to receive(:build_invited_identity).with("person@example.com").and_return(identity)

      expect(controller.send(:build_invited_account, "person@example.com")).to eq(identity)
    end
  end

  describe "#accept_pending_invitation" do
    it "does not accept an invitation reassigned before it obtains the invitation lock" do
      organisation = create(:organisation)
      account = create(:account)
      reassigned_account = create(:account)
      token = SecureRandom.uuid
      invitation = create(:user, account: account, organisation: organisation,
        invitation_token: token, invitation_sent_at: Time.current)
      published = []
      session[controller.send(:invited_user_session_key)] = {"token" => token}
      allow(controller).to receive(:pending_invited_identity).and_return(invitation)
      allow(controller).to receive(:publish_invitation_acceptance) { published << :invitation_acceptance }

      original_with_lock = invitation.method(:with_lock)
      reassigned = false
      invitation.define_singleton_method(:with_lock) do |*args, &block|
        unless reassigned
          User.where(id: id).update_all(account_id: reassigned_account.id)
          reassigned = true
        end
        original_with_lock.call(*args, &block)
      end

      expect(controller.send(:accept_pending_invitation, account)).to be_nil
      expect(invitation.reload.invitation_token).to eq(token)
      expect(published).to be_empty
    end
  end

  describe "session key helpers" do
    it "generates two_factor_session_key" do
      expect(controller.send(:two_factor_session_key)).to eq("warden.user.2fa_pending")
    end

    it "generates account_scope_name" do
      expect(controller.send(:account_scope_name)).to eq(:user_account)
    end

    it "generates impersonation_scope" do
      expect(controller.send(:impersonation_scope)).to eq(:user_impersonation)
    end

    it "generates return_to_session_key" do
      expect(controller.send(:return_to_session_key)).to eq("warden.user.return_to")
    end

    it "generates invited_user_session_key" do
      expect(controller.send(:invited_user_session_key)).to eq("warden.user.invited_user_id")
    end

    it "generates impersonation_return_to_session_key" do
      expect(controller.send(:impersonation_return_to_session_key)).to eq("warden.user.impersonation_return_to")
    end

    it "generates signed_in_via_session_key" do
      expect(controller.send(:signed_in_via_session_key)).to eq("warden.user.signed_in_via")
    end

    it "generates credential_drafts_session_key from the configured suffix" do
      expect(controller.send(:credential_drafts_session_key)).to eq("warden.user.credential_drafts")
    end

    it "honours a host override of credential_drafts_session_suffix" do
      original = Vouch.configuration.credential_drafts_session_suffix
      Vouch.configuration.credential_drafts_session_suffix = "reg_drafts"
      expect(controller.send(:credential_drafts_session_key)).to eq("warden.user.reg_drafts")
    ensure
      Vouch.configuration.credential_drafts_session_suffix = original
    end
  end

  describe "credential-drafts accessors" do
    let(:session_hash) { {} }
    before do
      allow(controller).to receive(:session).and_return(session_hash)
    end

    it "lazily seeds an empty hash for host-defined draft data" do
      expect(controller.send(:credential_drafts)).to eq({})
      expect(session_hash["warden.user.credential_drafts"]).to be_a(Hash)
    end

    it "assigns via credential_drafts=" do
      drafts = { "emails" => [:draft], "host_metadata" => { "source" => "invite" } }
      controller.send(:credential_drafts=, drafts)
      expect(session_hash["warden.user.credential_drafts"]).to eq(drafts)
    end

    it "clears via clear_credential_drafts" do
      session_hash["warden.user.credential_drafts"] = { "emails" => [:draft] }
      controller.send(:clear_credential_drafts)
      expect(session_hash).not_to have_key("warden.user.credential_drafts")
    end
  end

  describe "#signed_in_via" do
    let(:session_hash) { {} }
    before do
      allow(controller).to receive(:session).and_return(session_hash)
    end

    it "returns nil when the session slot is empty" do
      expect(controller.send(:signed_in_via)).to be_nil
    end

    it "returns the stored hash when present" do
      session_hash["warden.user.signed_in_via"] = { "type" => "Phone", "id" => "7" }
      expect(controller.send(:signed_in_via)).to eq("type" => "Phone", "id" => "7")
    end
  end

  describe "#two_factor_credentials_for with signed_in_via filter" do
    let(:session_hash) { {} }
    let(:phone_a) { instance_double("Phone", class: Phone, id: 7) }
    let(:phone_b) { instance_double("Phone", class: Phone, id: 8) }
    let(:mapping) { instance_double(Vouch::Mapping) }
    let(:assocs)  { [instance_double(ActiveRecord::Reflection::HasManyReflection)] }
    let(:account) { double("Account") }

    before do
      allow(controller).to receive(:session).and_return(session_hash)
      allow(controller).to receive(:auth_mapping).and_return(mapping)
      allow(mapping).to receive(:two_factor_credential_associations).and_return(assocs)
      stub_const("Phone", Class.new)
      set = instance_double(Vouch::CredentialSet)
      allow(Vouch::CredentialSet).to receive(:new).and_return(set)
      @set = set
    end

    it "returns the set unfiltered when signed_in_via is nil" do
      expect(@set).not_to receive(:reject)
      expect(controller.send(:two_factor_credentials_for, account)).to eq(@set)
    end

    it "applies a reject filter that hides the signed-in credential" do
      session_hash["warden.user.signed_in_via"] = { "type" => "Phone", "id" => "7" }

      filtered = instance_double(Vouch::CredentialSet)
      captured_block = nil
      allow(@set).to receive(:reject) { |&b| captured_block = b; filtered }

      expect(controller.send(:two_factor_credentials_for, account)).to eq(filtered)
      expect(captured_block.call(phone_a)).to be true
      expect(captured_block.call(phone_b)).to be false
    end
  end

  describe "#current_account" do
    before do
      mapping = Vouch::Mapping.new(:user, account: "Account", identity: "User")
      mapping.resolve_reflections!
      Vouch.mappings[:user] = mapping
    end

    let(:account) { create(:account) }
    let(:warden_proxy) { instance_double(Warden::Proxy) }

    before do
      allow(controller).to receive(:warden).and_return(warden_proxy)
    end

    it "returns the tier-2 account from the :user_account Warden scope" do
      allow(warden_proxy).to receive(:user).with(:user_account).and_return(account)
      allow(warden_proxy).to receive(:user).with(:user).and_return(nil)

      session['warden.user.selection'] = Vouch::PendingAuthentication.build(account,
        identities: [], method: :password, hook: :sign_in)
      expect(controller.send(:current_account)).to eq(account)
    end

    it "falls back to account_for(current_user) at tier 3" do
      user = create(:user, account: account)
      allow(warden_proxy).to receive(:user).with(:user_account).and_return(nil)
      allow(warden_proxy).to receive(:user).with(:user).and_return(user)

      session['warden.user.selection'] = Vouch::PendingAuthentication.build(account,
        identities: [], method: :password, hook: :sign_in)
      expect(controller.send(:current_account)).to eq(account)
    end

    it "returns nil when neither tier is active" do
      allow(warden_proxy).to receive(:user).with(:user_account).and_return(nil)
      allow(warden_proxy).to receive(:user).with(:user).and_return(nil)

      expect(controller.send(:current_account)).to be_nil
    end

    it "prefers tier 2 over tier 3 when both are present" do
      user = create(:user, account: account)
      other_account = create(:account)
      allow(warden_proxy).to receive(:user).with(:user_account).and_return(other_account)
      allow(warden_proxy).to receive(:user).with(:user).and_return(user)

      session['warden.user.selection'] = Vouch::PendingAuthentication.build(other_account,
        identities: [], method: :password, hook: :sign_in)
      expect(controller.send(:current_account)).to eq(other_account)
    end
  end

  describe "#candidate_identities_for" do
    before do
      mapping = Vouch::Mapping.new(:user, account: "Account", identity: "User")
      mapping.resolve_reflections!
      Vouch.mappings[:user] = mapping
    end

    let(:organisation) { create(:organisation) }
    let(:account) { create(:account) }
    let!(:user1) { create(:user, account: account, organisation: organisation) }
    let!(:user2) { create(:user, account: account, organisation: create(:organisation)) }

    it "defaults to auth_mapping.identities_for(account)" do
      result = controller.send(:candidate_identities_for, account)

      expect(result).to contain_exactly(user1, user2)
    end

    it "is the seam complete_sign_in calls" do
      narrowed = User.where(id: user1.id)
      allow(controller).to receive(:candidate_identities_for).with(account).and_return(narrowed)
      warden_proxy = instance_double(Warden::Proxy, set_user: nil)
      allow(controller).to receive(:warden).and_return(warden_proxy)
      allow(controller).to receive(:reset_session_with_preserved_keys)
      allow(controller).to receive(:run_hooks).and_yield(double(add: nil))

      result = controller.send(:complete_sign_in, account)

      expect(result).to eq(:signed_in)
      expect(warden_proxy).to have_received(:set_user).with(user1, scope: :user, store: true, event: :authentication)
    end

    it "denies sign-in when the locked factor recheck fails" do
      narrowed = User.where(id: user1.id)
      allow(controller).to receive(:candidate_identities_for).with(account).and_return(narrowed)
      allow(controller).to receive(:valid_context_factor?).with(account, anything).and_return(true, false)
      warden_proxy = instance_double(Warden::Proxy, set_user: nil)
      allow(controller).to receive(:warden).and_return(warden_proxy)
      allow(controller).to receive(:reset_session_with_preserved_keys)

      result = controller.send(:complete_sign_in, account)

      expect(result).to eq(:denied)
      expect(warden_proxy).not_to have_received(:set_user)
    end
  end

  describe "#single_identity_login?" do
    context "with a single-model mapping" do
      before do
        Vouch.mappings[:user] = Vouch::Mapping.new(:user, model: "Account")
      end

      it "returns true (not split-model)" do
        expect(controller.send(:single_identity_login?, [build(:account)])).to be true
      end
    end

    context "with a split-model mapping and one identity" do
      before do
        Vouch.mappings[:user] = Vouch::Mapping.new(
          :user, account: "Account", identity: "User"
        )
      end

      it "returns true when there is exactly one identity" do
        expect(controller.send(:single_identity_login?, [build(:user)])).to be true
      end
    end

    context "with a split-model mapping and multiple identities" do
      before do
        Vouch.mappings[:user] = Vouch::Mapping.new(
          :user, account: "Account", identity: "User"
        )
      end

      it "returns false when multiple identities exist" do
        expect(controller.send(:single_identity_login?, [build(:user), build(:user)])).to be false
      end
    end
  end
end
