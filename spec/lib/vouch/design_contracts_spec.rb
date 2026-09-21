require 'rails_helper'

RSpec.describe 'Authentication design contracts' do
  it 'rejects :invitable on the account of a split-model mapping' do
    stub_const('WronglyInvitableAccount', Class.new(Account) do
      authenticates_with :invitable
    end)

    mapping = Vouch::Mapping.new(:wrongly_invitable,
      account: 'WronglyInvitableAccount', identity: 'User')

    expect { mapping.resolve_reflections! }
      .to raise_error(
        Vouch::ConfigurationError,
        /WronglyInvitableAccount enables :invitable.*split-model.*User.*include Vouch::Invitable::Concern/i
      )
  end

  it 'allows invitations on the identity of a split-model mapping' do
    mapping = Vouch::Mapping.new(:invitable_identity, account: 'Account', identity: 'User')

    expect { mapping.resolve_reflections! }.not_to raise_error
  end

  it 'allows :invitable on a single-model mapping' do
    stub_const('InvitableMember', Class.new(Account) do
      authenticates_with :invitable
    end)
    mapping = Vouch::Mapping.new(:invitable_member, model: 'InvitableMember')

    expect { mapping.resolve_reflections! }.not_to raise_error
  end

  it 'retires a previous issuance without retiring a different flow' do
    phone = PhoneVerification.create!(e164: '+61400008881')
    verification = phone.start_verification!
    verification_code = phone.last_delivered_code
    first = phone.issue_sign_in_code!
    first_code = phone.last_delivered_sign_in_code
    latest = phone.issue_sign_in_code!
    latest_code = phone.last_delivered_sign_in_code
    expect(phone.verify_sign_in_code(first_code, token: first.token)).to be_invalid
    expect(phone.complete_verification!(verification_code, token: verification.token)).to be_ok
    expect(phone.verify_sign_in_code(latest_code, token: latest.token)).to be_ok
  end

  it 'rejects consumption from an instance loaded before another instance consumed the proof' do
    phone = PhoneVerification.create!(e164: '+61400008882')
    issued = phone.issue_sign_in_code!
    stale = PhoneVerification.find(phone.id)
    expect(phone.verify_sign_in_code(phone.last_delivered_sign_in_code, token: issued.token)).to be_ok
    expect(stale.verify_sign_in_code(phone.last_delivered_sign_in_code, token: issued.token)).to be_invalid
  end

  it 'validates required columns when the feature is used' do
    stub_const('MissingNonce', Class.new(ApplicationRecord) do
      self.table_name = 'organisations'
      include Vouch::MagicLinkable
    end)
    columns = Vouch::FeatureContracts.columns(:magic_linkable).to_h { |column| [column.to_s, double] }
    columns.delete('sign_in_nonce')
    allow(MissingNonce).to receive(:columns_hash).and_return(columns)
    expect { MissingNonce.new.issue_sign_in_code! }
      .to raise_error(Vouch::SchemaError, /sign_in_nonce/)
  end

  it 'requires explicit selection when both directions are ambiguous' do
    stub_const('CustomOwner', Class.new(ApplicationRecord) do
      self.table_name = 'accounts'
      has_many :members, class_name: 'CustomMember', foreign_key: :account_id
      has_many :other_members, class_name: 'CustomMember', foreign_key: :account_id
    end)
    stub_const('CustomMember', Class.new(ApplicationRecord) do
      self.table_name = 'users'
      belongs_to :owner, class_name: 'CustomOwner', foreign_key: :account_id
      belongs_to :other_owner, class_name: 'CustomOwner', foreign_key: :account_id
    end)
    expect { Vouch::Mapping.new(:custom, account: 'CustomOwner', identity: 'CustomMember').resolve_reflections! }
      .to raise_error(Vouch::ConfigurationError, /account_identities/)
    mapping = Vouch::Mapping.new(:custom, account: 'CustomOwner', identity: 'CustomMember',
      associations: {account_identities: :members, identity_account: :owner})
    mapping.resolve_reflections!
    account = create(:account)
    user = create(:user, account: account)
    expect(mapping.account_for(CustomMember.find(user.id))).to eq(CustomOwner.find(account.id))
    expect(mapping.identities_for(CustomOwner.find(account.id)).ids).to eq([user.id])
  end

  it 'uses the model password archive selection in every route scope' do
    stub_const('HistoryAccount', Class.new(Account) do
      has_many :old_passwords, class_name: 'PasswordArchive', foreign_key: :account_id
    end)
    HistoryAccount.auth_options = {password_trackable: {association: :old_passwords}}
    first = Vouch::Mapping.new(:first_history, model: 'HistoryAccount')
    second = Vouch::Mapping.new(:second_history, model: 'HistoryAccount')
    [first, second].each(&:resolve_reflections!)
    expect(first.password_archive_association.name).to eq(:old_passwords)
    expect(second.password_archive_association.name).to eq(:old_passwords)
    account = HistoryAccount.find(create(:account).id)
    account.update!(password: 'a-new-password', password_confirmation: 'a-new-password')
    expect(account.old_passwords.count).to eq(1)
    expect(account.update(password: 'password123', password_confirmation: 'password123')).to be false
  end
  it 'revokes established sessions when the host session version changes' do
    stub_const('VersionedAccount', Class.new(Account) do
      alias_attribute :auth_session_version, :consecutive_locks
    end)
    mapping = Vouch::Mapping.new(:versioned, model: 'VersionedAccount')
    Vouch::RouteBuilder.new(nil).send(:register_warden_scope, mapping)
    serializer = Warden::SessionSerializer.new({})
    account = VersionedAccount.find(create(:account).id)
    payload = serializer.versioned_serialize(account)
    expect(serializer.versioned_deserialize(payload)).to eq(account)
    account.update!(auth_session_version: 1)
    expect(serializer.versioned_deserialize(payload)).to be_nil
  end

end
