require 'rails_helper'

RSpec.describe 'Agreed model and mapping contracts' do
  it 'binds signed verification to the configured recipient' do
    stub_const('ContactLink', Class.new(InvitationLink))
    ContactLink.token_subject_attribute = :recipient_email
    link = ContactLink.create!(recipient_email: 'first@example.com')
    token = link.confirmation_token
    link.update!(recipient_email: 'second@example.com')
    expect(ContactLink.consume_token(token)).to be_invalid
    link.update!(recipient_email: 'first@example.com')
    expect(ContactLink.consume_token(token)).to be_invalid
  end

  it 'invalidates reset links after any password change' do
    account = create(:account)
    token = account.generate_password_reset_token!.value
    account.update!(password: 'replacement-password', password_confirmation: 'replacement-password')
    expect(account.reset_password_with_token!(token, password: 'another-password')).to be_invalid
  end

  it 'rejects the current password as a replacement' do
    account = create(:account)
    expect(account.update(password: 'password123')).to be false
    expect(account.errors[:password]).to be_present
  end

  it 'doubles duration after each expired lock' do
    account = create(:account)
    5.times { account.failed_login! }
    duration = account.current_lockout_duration
    travel duration + 1.second do
      account.failed_login!
      expect(account.current_lockout_duration).to eq(duration * 2)
    end
  end

  it 'uses password history without a registered route scope' do
    account = create(:account)
    account.update!(password: 'new-password-123', password_confirmation: 'new-password-123')
    expect(account.password_archives.count).to eq(1)
    expect(account.update(password: 'password123')).to be false
  end

  it 'restores a session through a renamed primary key' do
    account = create(:account)
    stub_const('LegacyAccount', Class.new(Account) { self.primary_key = 'email_address' })
    mapping = Vouch::Mapping.new(:legacy, model: 'LegacyAccount')
    builder = Vouch::RouteBuilder.new(nil)
    builder.send(:register_warden_scope, mapping)
    serializer = Warden::SessionSerializer.new({})
    identity = LegacyAccount.find(account.email_address)
    payload = serializer.legacy_serialize(identity)
    expect(serializer.legacy_deserialize(payload)).to eq(identity)
  end

  it 'ignores an unrelated polymorphic association during tenant discovery' do
    stub_const('PolymorphicUser', Class.new(ApplicationRecord) do
      self.table_name = 'users'
      belongs_to :profileable, polymorphic: true
      belongs_to :account, class_name: 'PolymorphicAccount'
      belongs_to :organisation, class_name: 'PolymorphicOrganisation'
    end)
    stub_const('PolymorphicOrganisation', Class.new(ApplicationRecord) do
      self.table_name = 'organisations'
      has_many :members, class_name: 'PolymorphicUser', foreign_key: :organisation_id
    end)
    stub_const('PolymorphicAccount', Class.new(ApplicationRecord) do
      self.table_name = 'accounts'
      has_many :users, class_name: 'PolymorphicUser', foreign_key: :account_id
    end)
    mapping = Vouch::Mapping.new(:poly, account: 'PolymorphicAccount', identity: 'PolymorphicUser',
      associations: {account_identities: :users}, tenant: 'PolymorphicOrganisation')
    expect { mapping.resolve_reflections! }.not_to raise_error
    expect(mapping.identity_tenant_association.name).to eq(:organisation)
  end

  it 'supports flat association overrides with custom route paths' do
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw do
      Vouch.routes(self) do |auth|
        auth.scope :customer, account: 'Account', identity: 'User', tenant: 'Organisation',
          path: 'members', as: :member,
          associations: {account_identities: :users, identity_account: :account,
            identity_tenant: :organisation, tenant_identities: :users} do
          auth.sessions(path_names: {sign_in: 'login'}, controller: 'members/sessions')
        end
      end
    end
    expect(routes.url_helpers.new_member_session_path).to eq('/members/login')
    expect(Vouch.mapping_for(:customer).identities_for(create(:account))).to be_empty
  ensure
    Vouch.deregister_mapping(:customer)
  end

  it 'loads credential classes before their feature migration runs' do
    stub_const('UnmigratedCredential', Class.new(ApplicationRecord) { self.table_name = 'not_migrated_credentials' })
    expect { UnmigratedCredential.include(Vouch::Verifiable) }.not_to raise_error
    expect { UnmigratedCredential.include(Vouch::TwoFactorable) }.not_to raise_error
    expect { UnmigratedCredential.include(Vouch::MagicLinkable) }.not_to raise_error
  end
end
