require 'rails_helper'

RSpec.describe 'Account-level MFA policy', type: :request do
  def ready_credential(account, enabled: true)
    account.two_factor_credentials.create!(
      verified_at: Time.current,
      two_factor_enabled_at: enabled ? Time.current : nil
    )
  end

  it 'keeps a ready credential independent from the account MFA preference' do
    account = create(:account)
    credential = ready_credential(account)

    expect(credential).to be_two_factor_enabled
    expect(account.reload).not_to be_two_factor_enabled
    expect(account.class.auth_config(:two_factorable)).to be_present
  end

  it 'requires a usable factor before enabling account MFA' do
    account = create(:account)

    expect { account.enable_two_factor! }
      .to raise_error(Vouch::ConfigurationError, /usable credential/)
    expect(account.reload).not_to be_two_factor_enabled
  end

  it 'allows explicit account disable and persists the preference atomically' do
    account = create(:account)
    ready_credential(account)
    account.enable_two_factor!

    account.disable_two_factor!

    expect(account.reload).not_to be_two_factor_enabled
  end

  it 'rejects disabling the last usable factor while account MFA is enabled' do
    account = create(:account)
    credential = ready_credential(account)
    account.enable_two_factor!

    expect { credential.disable_two_factor! }
      .to raise_error(Vouch::TwoFactorable::LastFactorRemoval)
    expect(credential.reload).to be_two_factor_enabled
    expect(account.reload).to be_two_factor_enabled
  end

  it 'rejects deleting the last usable factor through the HTTP endpoint' do
    account = create(:account)
    user = create(:user, account: account)
    credential = ready_credential(account)
    account.enable_two_factor!
    sign_in(user)

    delete "/users/two_factor_credentials/#{credential.id}"

    expect(response).to redirect_to('/users/two_factor_credentials')
    expect(flash[:alert]).to be_present
    expect(credential.class.exists?(credential.id)).to be true
    expect(account.reload).to be_two_factor_enabled
  end

  it 'allows removing a disabled credential while another usable factor remains' do
    account = create(:account)
    removable = account.two_factor_credentials.create!(verified_at: Time.current)
    ready_credential(account)
    account.enable_two_factor!

    expect { removable.destroy! }.not_to raise_error
    expect(account.reload).to be_two_factor_enabled
  end

  it 'allows the host to disable account MFA when the last factor is removed' do
    account = create(:account)
    credential = ready_credential(account)
    account.enable_two_factor!
    account.define_singleton_method(:two_factor_last_factor_removal_action) { |_credential| :disable }

    expect { credential.disable_two_factor! }.not_to raise_error
    expect(credential.reload).not_to be_two_factor_enabled
    expect(account.reload).not_to be_two_factor_enabled
  end

  it 'rolls back an account disable when the final credential destroy is aborted' do
    account = create(:account)
    credential = ready_credential(account)
    account.enable_two_factor!
    account.define_singleton_method(:two_factor_last_factor_removal_action) { |_credential| :disable }
    callback = proc { throw :abort }
    credential.class.set_callback(:destroy, :before, callback)

    expect(credential.destroy).to be false
    expect(credential.class.exists?(credential.id)).to be true
    expect(account.reload).to be_two_factor_enabled
  ensure
    credential.class.skip_callback(:destroy, :before, callback) if callback
  end

  it 'reloads the owner after acquiring its lock before applying removal policy' do
    account = create(:account)
    credential = ready_credential(account)
    account.enable_two_factor!
    stale_owner = credential.account
    stale_owner.update_column(:two_factor_enabled, false)
    credential.update_column(:two_factor_enabled_at, nil)
    Account.where(id: account.id).update_all(two_factor_enabled: true)
    TwoFactorCredential.where(id: credential.id).update_all(two_factor_enabled_at: Time.current)

    expect { credential.disable_two_factor! }
      .to raise_error(Vouch::TwoFactorable::LastFactorRemoval)
    expect(credential.reload).to be_two_factor_enabled
    expect(account.reload).to be_two_factor_enabled
  end

end
