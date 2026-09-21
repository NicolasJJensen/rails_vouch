# frozen_string_literal: true

require "rails_helper"

RSpec.describe "OAuth account ownership" do
  let(:auth_hash) do
    OmniAuth::AuthHash.new(
      provider: "example",
      uid: "oauth-owner-123",
      info: { email: "owner@example.com", name: "Owner" },
      credentials: { token: "secret-token", secret: "secret-value" },
      extra: { raw: "provider-internal" }
    )
  end

  it "does not persist raw OAuth credentials by default" do
    attributes = OmniAuthIdentity.oauth_attributes(auth_hash)

    expect(attributes.keys).to contain_exactly(:provider, :uid, :auth_data)
    expect(JSON.parse(attributes.fetch(:auth_data))).to eq(
      "provider" => "example",
      "uid" => "oauth-owner-123",
      "info" => {"email" => "owner@example.com", "name" => "Owner"}
    )
  end

  it "allows a host override to explicitly persist raw OAuth data" do
    host = Class.new(OmniAuthIdentity)
    host.define_singleton_method(:oauth_attributes) do |received|
      super(received).merge(auth_data: received.to_json)
    end

    attributes = host.oauth_attributes(auth_hash)

    expect(attributes[:auth_data]).to include("secret-token", "provider-internal")
  end

  it "resolves the generated polymorphic owner independently of the membership owner" do
    stub_const("GeneratedOauthAccount", Class.new(Account) do
      has_many :generated_oauth_identities,
               as: :account,
               class_name: "GeneratedOauthIdentity"
    end)
    stub_const("GeneratedOauthIdentity", Class.new(ApplicationRecord) do
      self.table_name = "omni_auth_identities"
      attribute :account_type, :string

      include Vouch::OAuthIdentity::Concern
      belongs_to :account, polymorphic: true
    end)
    stub_const("GeneratedMembership", Class.new(User) do
      belongs_to :owner,
                 class_name: "GeneratedOauthAccount",
                 foreign_key: :account_id
    end)
    GeneratedOauthAccount.has_many :memberships,
                                   class_name: "GeneratedMembership",
                                   foreign_key: :account_id

    mapping = Vouch::Mapping.new(
      :generated,
      account: "GeneratedOauthAccount",
      identity: "GeneratedMembership",
      associations: {
        account_identities: :memberships,
        identity_account: :owner,
        omniauthable: :generated_oauth_identities
      }
    ).tap(&:resolve_reflections!)
    account = GeneratedOauthAccount.new
    oauth_identity = GeneratedOauthIdentity.new(account: account)

    expect(mapping.account_association).to eq(:owner)
    expect(mapping.oauth_account_association.name).to eq(:account)
    expect(mapping.account_for_oauth_identity(oauth_identity)).to equal(account)
  end

  it "discovers an unambiguous custom belongs_to owner" do
    stub_const("CustomOauthAccount", Class.new(Account) do
      has_many :custom_oauth_identities,
               class_name: "CustomOauthIdentity",
               foreign_key: :account_id
    end)
    stub_const("CustomOauthIdentity", Class.new(ApplicationRecord) do
      self.table_name = "omni_auth_identities"

      include Vouch::OAuthIdentity::Concern
      belongs_to :owner,
                 class_name: "CustomOauthAccount",
                 foreign_key: :account_id
    end)

    mapping = Vouch::Mapping.new(
      :custom_oauth,
      model: "CustomOauthAccount",
      associations: { omniauthable: :custom_oauth_identities }
    ).tap(&:resolve_reflections!)
    account = CustomOauthAccount.new
    oauth_identity = CustomOauthIdentity.new(owner: account)

    expect(mapping.oauth_account_association.name).to eq(:owner)
    expect(mapping.account_for_oauth_identity(oauth_identity)).to equal(account)

    built = mapping.oauth_identity_class.build_from_omniauth(auth_hash, account: account)
    expect(built.owner).to equal(account)
  end

  it "accepts a base-class OAuth owner for an account subclass" do
    stub_const("SpecializedOauthAccount", Class.new(Account))
    account = SpecializedOauthAccount.new

    built = OmniAuthIdentity.build_from_omniauth(auth_hash, account: account)

    expect(built.account).to equal(account)
  end

  it "requires an explicit OAuth owner when multiple belongs_to associations match" do
    stub_const("AmbiguousOauthAccount", Class.new(Account) do
      has_many :ambiguous_oauth_identities,
               class_name: "AmbiguousOauthIdentity",
               foreign_key: :account_id
    end)
    stub_const("AmbiguousOauthIdentity", Class.new(ApplicationRecord) do
      self.table_name = "omni_auth_identities"

      include Vouch::OAuthIdentity::Concern
      belongs_to :owner,
                 class_name: "AmbiguousOauthAccount",
                 foreign_key: :account_id
      belongs_to :billing_owner,
                 class_name: "AmbiguousOauthAccount",
                 foreign_key: :account_id
    end)

    mapping = Vouch::Mapping.new(
      :ambiguous_oauth,
      model: "AmbiguousOauthAccount",
      associations: { omniauthable: :ambiguous_oauth_identities }
    )

    expect { mapping.resolve_reflections! }
      .to raise_error(
        Vouch::ConfigurationError,
        /ambiguous oauth_account associations.*associations: \{ oauth_account: :name \}/i
      )
  end

  it "uses the explicit OAuth owner override for lookup and building" do
    stub_const("ExplicitOauthAccount", Class.new(Account) do
      has_many :explicit_oauth_identities,
               class_name: "ExplicitOauthIdentity",
               foreign_key: :account_id
    end)
    stub_const("ExplicitOauthIdentity", Class.new(ApplicationRecord) do
      self.table_name = "omni_auth_identities"

      include Vouch::OAuthIdentity::Concern
      belongs_to :owner,
                 class_name: "ExplicitOauthAccount",
                 foreign_key: :account_id
      belongs_to :billing_owner,
                 class_name: "ExplicitOauthAccount",
                 foreign_key: :account_id
    end)

    mapping = Vouch::Mapping.new(
      :explicit_oauth,
      model: "ExplicitOauthAccount",
      associations: {
        omniauthable: :explicit_oauth_identities,
        oauth_account: :owner
      }
    ).tap(&:resolve_reflections!)
    account = ExplicitOauthAccount.new

    expect(mapping.oauth_account_association.name).to eq(:owner)
    expect(mapping.account_for_oauth_identity(ExplicitOauthIdentity.new(owner: account))).to equal(account)

    built = mapping.oauth_identity_class.build_from_omniauth(
      auth_hash,
      account: account,
      oauth_account_association: mapping.oauth_account_association
    )
    expect(built.owner).to equal(account)
    expect(built.billing_owner).to be_nil
  end
end
