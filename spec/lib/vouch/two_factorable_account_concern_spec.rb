# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::TwoFactorable::AccountConcern do
  let(:account_class) do
    Class.new(Account).tap do |klass|
      klass.table_name = Account.table_name
    end
  end

  let(:account) { account_class.new }

  def reflection(name)
    double("Reflection", name: name, klass: TwoFactorCredential)
  end

  def mapping(scope, associations, klass: account_class)
    double("Mapping", scope_name: scope, account_class: klass,
      two_factor_credential_associations: associations)
  end

  def with_mappings(*mappings)
    allow(Vouch).to receive(:each_mapping) do |&block|
      mappings.each(&block)
    end
    allow(Vouch).to receive(:mapping_for) do |scope|
      mappings.find { |candidate| candidate.scope_name.to_sym == scope.to_sym } ||
        raise(ArgumentError, "unknown mapping")
    end
  end

  it "discovers the same account factor collection regardless of mapping order" do
    primary = reflection(:two_factor_credentials)
    secondary = reflection(:backup_two_factor_credentials)
    first_order = [mapping(:primary, [primary, secondary]), mapping(:secondary, [primary, secondary])]
    second_order = first_order.reverse

    with_mappings(*first_order)
    first = account.two_factor_credential_associations.map(&:name)

    with_mappings(*second_order)
    second = account.two_factor_credential_associations.map(&:name)

    expect(second).to eq(first)
  end

  it "does not mutate a mapping's association order while normalizing it" do
    associations = [reflection(:z_factor), reflection(:a_factor)]
    with_mappings(mapping(:primary, associations), mapping(:secondary, associations.reverse))

    account.two_factor_credential_associations

    expect(associations.map(&:name)).to eq(%i[z_factor a_factor])
  end

  it "accepts matching factor collections when mappings list them in different orders" do
    primary = reflection(:two_factor_credentials)
    secondary = reflection(:backup_two_factor_credentials)
    with_mappings(
      mapping(:primary, [primary, secondary]),
      mapping(:secondary, [secondary, primary])
    )

    expect(account.two_factor_credential_associations.map(&:name)).to match_array(
      %i[two_factor_credentials backup_two_factor_credentials]
    )
  end

  it "raises a clear configuration error when mappings disagree about factor collections" do
    primary = reflection(:two_factor_credentials)
    secondary = reflection(:backup_two_factor_credentials)
    with_mappings(mapping(:primary, [primary]), mapping(:secondary, [secondary]))

    expect { account.two_factor_credential_associations }
      .to raise_error(Vouch::ConfigurationError, /conflicting.*two.factor/i)
  end

  it "uses the reflection fallback when no mapping is registered" do
    allow(Vouch).to receive(:each_mapping)
    allow(account_class).to receive(:reflect_on_all_associations).with(:has_many).and_return(
      [reflection(:two_factor_credentials)]
    )

    expect(account.two_factor_credential_associations.map(&:name).first).to eq(:two_factor_credentials)
  end

  it "ignores mappings for an unrelated account class" do
    factor = reflection(:two_factor_credentials)
    with_mappings(mapping(:other, [factor], klass: Organisation))
    allow(account_class).to receive(:reflect_on_all_associations).with(:has_many).and_return([])

    expect(account.two_factor_credential_associations).to eq([])
  end

  it "applies a base account mapping to an account subclass while ignoring other classes" do
    base_factor = reflection(:two_factor_credentials)
    unrelated_factor = reflection(:other_two_factor_credentials)
    with_mappings(
      mapping(:base, [base_factor], klass: Account),
      mapping(:other, [unrelated_factor], klass: Organisation)
    )

    expect(account.two_factor_credential_associations.map(&:name)).to eq([:two_factor_credentials])
  end

  it "returns no factors when every applicable mapping is explicitly empty" do
    with_mappings(mapping(:primary, []), mapping(:secondary, []))
    allow(account_class).to receive(:reflect_on_all_associations).with(:has_many).and_return(
      [reflection(:two_factor_credentials)]
    )

    expect(account.two_factor_credential_associations).to eq([])
  end

  it "preserves an explicit account enabled attribute with one mapping" do
    account_class.two_factor_enabled_attribute = :mfa_enabled
    expect(account_class.two_factor_enabled_attribute).to eq(:mfa_enabled)

    with_mappings(mapping(:primary, [reflection(:two_factor_credentials)]))
    expect(account.two_factor_credential_associations.map(&:name)).to eq([:two_factor_credentials])
  end

  it "does not enable MFA by silently selecting one conflicting mapping" do
    primary = reflection(:two_factor_credentials)
    secondary = reflection(:backup_two_factor_credentials)
    with_mappings(mapping(:primary, [primary]), mapping(:secondary, [secondary]))
    persisted_account = account_class.new(
      email_address: "mfa-conflict@example.com",
      password_digest: BCrypt::Password.create("password123")
    )
    persisted_account.save!(validate: false)
    usable = double("Credential", two_factor_enabled?: true, verified?: true, two_factor_locked?: false)
    persisted_account.define_singleton_method(:two_factor_credentials) { [usable] }
    persisted_account.define_singleton_method(:backup_two_factor_credentials) { [usable] }

    expect { persisted_account.enable_two_factor! }
      .to raise_error(Vouch::ConfigurationError, /conflicting.*two.factor/i)
  end
end
