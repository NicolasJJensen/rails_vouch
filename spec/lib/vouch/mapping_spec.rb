# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::Mapping do
  describe "split-model mapping" do
    subject(:mapping) do
      described_class.new(:user, account: "Account", identity: "User")
    end

    it "stores the scope name" do
      expect(mapping.scope_name).to eq(:user)
    end

    it "stores account class name" do
      expect(mapping.account_class_name).to eq("Account")
    end

    it "stores identity class name" do
      expect(mapping.identity_class_name).to eq("User")
    end

    it "is a split model" do
      expect(mapping).to be_split_model
    end

    it "resolves account class" do
      expect(mapping.account_class).to eq(Account)
    end

    it "resolves identity class" do
      expect(mapping.identity_class).to eq(User)
    end

    it "defaults path to pluralized scope" do
      expect(mapping.path).to eq("users")
    end

    it "defaults helper prefix to scope name" do
      expect(mapping.helper_prefix).to eq(:user)
    end

    it "resolves identities from an account" do
      account = create(:account)
      org = create(:organisation)
      user = create(:user, account: account, organisation: org)

      identities = mapping.identities_for(account)
      expect(identities).to include(user)
    end
  end

  describe "single-model mapping" do
    subject(:mapping) do
      described_class.new(:member, model: "Account")
    end

    it "is not a split model" do
      expect(mapping).not_to be_split_model
    end

    it "uses the same class for account and identity" do
      expect(mapping.account_class_name).to eq("Account")
      expect(mapping.identity_class_name).to eq("Account")
    end

    it "returns the account itself as identity" do
      account = create(:account)
      expect(mapping.identities_for(account)).to eq([account])
    end

    it "resolves a separate OAuth identity through its owner association" do
      account = create(:account)
      oauth_identity = build(:omni_auth_identity, account: account)

      expect(mapping.account_for_oauth_identity(oauth_identity)).to eq(account)
    end
  end

  describe "validation" do
    it "raises when neither model nor account+identity provided" do
      expect {
        described_class.new(:user, account: "Account")
      }.to raise_error(ArgumentError, /Provide either model: or both account: and identity:/)
    end

    it "rejects model combined with account or identity" do
      expect {
        described_class.new(:member, model: "Account", account: "OtherAccount")
      }.to raise_error(Vouch::ConfigurationError, /model.*account/i)

      expect {
        described_class.new(:member, model: "Account", identity: "OtherIdentity")
      }.to raise_error(Vouch::ConfigurationError, /model.*identity/i)
    end

    it "rejects tenant on a single-model mapping" do
      expect {
        described_class.new(:member, model: "Account", tenant: "Organisation")
      }.to raise_error(Vouch::ConfigurationError, /model.*tenant|tenant.*model/i)
    end

    it "rejects an unsupported association key" do
      expect {
        described_class.new(:user, account: "Account", identity: "User",
          associations: { account_identites: :users })
      }.to raise_error(Vouch::ConfigurationError, /account_identites/)
    end
  end

  describe "tenant support" do
    subject(:mapping) do
      described_class.new(:user, account: "Account", identity: "User", tenant: "Organisation").tap(&:resolve_reflections!)
    end

    it "stores tenant class name" do
      expect(mapping.tenant_class_name).to eq("Organisation")
    end

    it "is a tenant mapping" do
      expect(mapping).to be_tenant
    end

    it "resolves tenant class" do
      expect(mapping.tenant_class).to eq(Organisation)
    end

    it "finds the has_many from tenant to identity" do
      assoc = mapping.tenant_identity_association
      expect(assoc).to be_present
      expect(assoc.name).to eq(:users)
      expect(assoc.klass).to eq(User)
    end

    it "finds the belongs_to from identity to tenant" do
      assoc = mapping.identity_tenant_association
      expect(assoc).to be_present
      expect(assoc.name).to eq(:organisation)
      expect(assoc.klass).to eq(Organisation)
    end
  end

  describe "mapping without tenant" do
    subject(:mapping) do
      described_class.new(:user, account: "Account", identity: "User").tap(&:resolve_reflections!)
    end

    it "is not a tenant mapping" do
      expect(mapping).not_to be_tenant
    end

    it "returns nil for tenant class" do
      expect(mapping.tenant_class).to be_nil
    end

    it "returns nil for tenant associations" do
      expect(mapping.tenant_identity_association).to be_nil
      expect(mapping.identity_tenant_association).to be_nil
    end
  end

  describe "OAuth identity reflection" do
    subject(:mapping) do
      described_class.new(:user, account: "Account", identity: "User").tap(&:resolve_reflections!)
    end

    it "discovers the OAuth identity association via concern inclusion" do
      assoc = mapping.oauth_identity_association
      expect(assoc).to be_present
      expect(assoc.klass).to eq(OmniAuthIdentity)
    end

    it "returns the OAuth identity class" do
      expect(mapping.oauth_identity_class).to eq(OmniAuthIdentity)
    end
  end

  describe "TwoFactorable reflection" do
    subject(:mapping) do
      described_class.new(:user, account: "Account", identity: "User").tap(&:resolve_reflections!)
    end

    it "exposes two_factor_credential_associations as a list" do
      assocs = mapping.two_factor_credential_associations
      expect(assocs).to be_an(Array)
      expect(assocs).not_to be_empty
      expect(assocs.map(&:klass)).to include(TwoFactorCredential)
    end

    it "keeps the singular accessor returning the first match for back-compat" do
      expect(mapping.two_factor_credential_association).to eq(
        mapping.two_factor_credential_associations.first
      )
    end

    it "discovers every TwoFactorable target when the account has more than one" do
      # Stub a second has_many target that also includes TwoFactorable. We
      # mirror the real TwoFactorCredential reflection rather than building
      # a sibling AR class — keeps the spec hermetic.
      tfc_reflection = Account.reflect_on_all_associations(:has_many).find { |a| a.klass == TwoFactorCredential }
      fake_reflection = double("Reflection", name: :alt_two_factor_credentials, klass: TwoFactorCredential, polymorphic?: false)

      reflections = Account.reflect_on_all_associations(:has_many) + [fake_reflection]
      allow(Account).to receive(:reflect_on_all_associations).with(:has_many).and_return(reflections)

      m = described_class.new(:user, account: "Account", identity: "User").tap(&:resolve_reflections!)
      expect(m.two_factor_credential_associations).to include(tfc_reflection, fake_reflection)
    end

    it "raises when :two_factorable is enabled but no association includes the concern" do
      # Strip every reflection whose target ancestors include TwoFactorable;
      # keep the rest so validate_identity_association! still finds :users.
      surviving = Account.reflect_on_all_associations(:has_many).reject do |a|
        a.klass.ancestors.include?(Vouch::TwoFactorable)
      end
      allow(Account).to receive(:reflect_on_all_associations).with(:has_many).and_return(surviving)

      expect {
        described_class.new(:user, account: "Account", identity: "User").tap(&:resolve_reflections!)
      }.to raise_error(Vouch::ConfigurationError, /no has_many target includes Vouch::TwoFactorable/)
    end

    it "rejects an empty explicit association list when :two_factorable is enabled" do
      expect {
        described_class.new(:user, account: "Account", identity: "User",
          associations: { two_factorable: [] }).resolve_reflections!
      }.to raise_error(Vouch::ConfigurationError, /two_factorable.*no has_many target/i)
    end

    it "accepts a nonempty explicit association list when :two_factorable is enabled" do
      mapping = described_class.new(:user, account: "Account", identity: "User",
        associations: { two_factorable: [:two_factor_credentials] }).tap(&:resolve_reflections!)

      expect(mapping.two_factor_credential_associations.map(&:name)).to eq([:two_factor_credentials])
    end
  end

  describe "custom options" do
    subject(:mapping) do
      described_class.new(:admin, account: "Account", identity: "User",
                          path: "admin", as: :admin_user)
    end

    it "uses custom path" do
      expect(mapping.path).to eq("admin")
    end

    it "uses custom helper prefix" do
      expect(mapping.helper_prefix).to eq(:admin_user)
    end
  end

  describe "resolved identity and account associations" do
    it "defaults identity_association to pluralized identity class" do
      mapping = described_class.new(:user, account: "Account", identity: "User")
      expect(mapping.identity_association).to eq(:users)
    end

    it "uses an associations override for the identity collection" do
      mapping = described_class.new(:user, account: "Account", identity: "User",
                                    associations: {account_identities: :members})
      expect(mapping.identity_association).to eq(:members)
    end

    it "defaults account_association to :account" do
      mapping = described_class.new(:user, account: "Account", identity: "User")
      expect(mapping.account_association).to eq(:account)
    end

    it "uses an associations override for the identity owner" do
      mapping = described_class.new(:user, account: "Account", identity: "User",
                                    associations: {identity_account: :auth_account})
      expect(mapping.account_association).to eq(:auth_account)
    end

    it "rejects removed relationship alias keywords" do
      expect {
        described_class.new(
          :user, account: "Account", identity: "User",
          identity_association: :members
        )
      }.to raise_error(ArgumentError, /unknown keyword: :identity_association/)

      expect {
        described_class.new(
          :user, account: "Account", identity: "User",
          account_association: :owner
        )
      }.to raise_error(ArgumentError, /unknown keyword: :account_association/)
    end

    it "uses the custom account association for OAuth identities" do
      mapping = described_class.new(:user, account: "Account", identity: "User",
                                    associations: {identity_account: :account}).tap(&:resolve_reflections!)

      identity = build(:omni_auth_identity, account: build(:account))
      expect(mapping.account_for_oauth_identity(identity)).to eq(identity.account)
    end

    it "accepts an explicit OAuth association without scanning unrelated targets" do
      mapping = described_class.new(
        :user, account: "Account", identity: "User",
        associations: { omniauthable: :omni_auth_identities }
      ).tap(&:resolve_reflections!)

      expect(mapping.oauth_identity_association.name).to eq(:omni_auth_identities)
    end
  end

  describe "OAuth route settings" do
    it "stores scope-specific callback paths and methods" do
      mapping = described_class.new(
        :user, account: "Account", identity: "User",
        oauth_callback_path: "/members/auth/:provider/callback",
        oauth_failure_path: "/members/auth/failure",
        oauth_callback_methods: %i[get post],
        oauth_failure_methods: :post
      )

      expect(mapping.oauth_callback_path).to eq("/members/auth/:provider/callback")
      expect(mapping.oauth_failure_path).to eq("/members/auth/failure")
      expect(mapping.oauth_callback_methods).to eq(%w[GET POST])
      expect(mapping.oauth_failure_methods).to eq(["POST"])
    end
  end

  describe "boot validation" do
    it "raises when identity association is missing on account class" do
      mapping = described_class.new(:user, account: "Account", identity: "User",
                                    associations: {account_identities: :nonexistent_assoc})
      expect {
        mapping.resolve_reflections!
      }.to raise_error(Vouch::ConfigurationError, /does not have a has_many :nonexistent_assoc/)
    end

    it "raises with actionable error for missing tenant -> identity association" do
      # Stub tenant class with no has_many targeting identity
      stub_const("FakeTenant", Class.new(ApplicationRecord) { self.table_name = "organisations" })

      mapping = described_class.new(:user, account: "Account", identity: "User", tenant: "FakeTenant")
      expect {
        mapping.resolve_reflections!
      }.to raise_error(Vouch::ConfigurationError, /does not have a has_many association targeting/)
    end

    it "raises with actionable error when concern target class cannot be loaded" do
      # Use single-model mapping to skip validate_identity_association!
      bad_assoc = double("assoc", name: :broken_things)
      allow(bad_assoc).to receive(:klass).and_raise(NameError.new("uninitialized constant BrokenModel"))
      allow(Account).to receive(:reflect_on_all_associations).with(:has_many).and_return([bad_assoc])

      mapping = described_class.new(:member, model: "Account")
      expect {
        mapping.resolve_reflections!
      }.to raise_error(Vouch::ConfigurationError, /could not be loaded/)
    end
  end
end
