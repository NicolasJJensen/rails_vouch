require 'rails_helper'

RSpec.describe 'Controller integration policy' do
  let(:controller) { Users::SessionsController.new }
  let(:session) { {} }
  let(:proxy) { instance_double(Warden::Proxy) }

  before do
    allow(controller).to receive(:session).and_return(session)
    allow(controller).to receive(:warden).and_return(proxy)
    allow(proxy).to receive(:logout)
    allow(controller).to receive(:reset_session) { session.clear }
  end

  it 'R14 uses the configured scope even when host current_user is different' do
    controller.class.auth_scope :user
    identity = create(:user)
    allow(proxy).to receive(:user).with(:user).and_return(identity)
    controller.define_singleton_method(:current_user) { raise 'Wrong scope accessor' }
    expect(controller.send(:current_identity)).to eq(identity)
  end

  it 'renews authentication without clearing application state' do
    session['cart'] = {'items' => [1]}
    session['discard'] = 'old'
    controller.send(:renew_authentication_session)
    expect(session).to include('cart' => {'items' => [1]})
    expect(session['discard']).to eq('old')
    expect(proxy).to have_received(:logout).with(:user, :user_account, :user_impersonation)
  end

  it 'clears stale authentication challenges while leaving unrelated scopes alone' do
    session['warden.user.2fa_pending'] = { 'stale' => true }
    session['warden.user.two_factor_token.Phone.1'] = 'old'
    session['warden.admin.return_to'] = '/admin'
    controller.send(:renew_authentication_session)
    expect(session).not_to have_key('warden.user.2fa_pending')
    expect(session).not_to have_key('warden.user.two_factor_token.Phone.1')
    expect(session['warden.admin.return_to']).to eq('/admin')
    expect(proxy).not_to have_received(:logout).with(:admin)
    expect(controller).not_to have_received(:reset_session)
  end

  it 'stores an MFA continuation only after rotating the session' do
    account = create(:account)
    identity = create(:user, account: account)
    context = Vouch::PendingAuthentication.build(account, identities: [identity], method: :password, hook: :sign_in)
    session[controller.send(:return_to_session_key)] = '/reports'
    session['discard'] = 'old'

    controller.send(:authentication_session).begin_second_factor!(context,
      primary: {'type' => 'MagicLink', 'id' => '42'})

    expect(session).to include(
      controller.send(:return_to_session_key) => '/reports',
      controller.send(:two_factor_session_key) => context,
      controller.send(:signed_in_via_session_key) => {'type' => 'MagicLink', 'id' => '42'}
    )
    expect(context).to include('factor_required' => true)
    expect(session['discard']).to eq('old')
  end

  it 'stores the pending account in Warden only after rotating for identity selection' do
    account = create(:account)
    identity = create(:user, account: account)
    context = Vouch::PendingAuthentication.build(account, identities: [identity], method: :password, hook: :sign_in)

    expect(proxy).to receive(:set_user).with(account, scope: :user_account, store: true)
    controller.send(:authentication_session).begin_selection!(account, context)

    expect(session[controller.send(:selection_session_key)]).to eq(context)
  end

  it 'clears an invalid MFA continuation without clearing its challenge token' do
    account = create(:account)
    identity = create(:user, account: account)
    context = Vouch::PendingAuthentication.build(account, identities: [identity], method: :password, hook: :sign_in)
    key = controller.send(:two_factor_session_key)
    token_key = 'warden.user.two_factor_token.Phone.42'
    session[key] = context.merge('fingerprint' => 'invalid')
    session[token_key] = 'challenge-token'

    expect(controller.send(:authentication_session).load_second_factor).to be_nil
    expect(session).not_to have_key(key)
    expect(session[token_key]).to eq('challenge-token')
  end

  it 'round-trips an OAuth registration continuation through the host serializers' do
    auth_hash = OmniAuth::AuthHash.new(provider: 'google', uid: '123', info: {email: 'member@example.com'})
    auth_session = controller.send(:authentication_session)

    auth_session.begin_oauth_registration!(auth_hash)

    expect(auth_session.oauth_registration_present?).to be(true)
    expect(auth_session.load_oauth_registration).to include('provider' => 'google', 'uid' => '123')
  end

  it 'policy allows an explicitly trusted OAuth provider to satisfy MFA' do
    account = create(:account)
    allow(account).to receive(:two_factor_enabled?).and_return(true)
    allow(Vouch.configuration).to receive(:oauth_mfa_providers).and_return(['company'])
    policy = Vouch::AuthenticationPolicy.new
    expect(policy.two_factor_required?(account, method: :oauth, provider: 'company', controller: controller)).to be false
    expect(policy.two_factor_required?(account, method: :oauth, provider: 'public', controller: controller)).to be true
  end

  it 'instantiates a configured policy once for the lifetime of a controller request' do
    policy_class = Class.new do
      class << self
        attr_accessor :instances
      end
      self.instances = []

      def initialize
        self.class.instances << self
      end

      def allowed?(*); true; end
      def two_factor_required?(*); false; end
    end
    stub_const('RequestPolicy', policy_class)
    original_policy = Vouch.configuration.authentication_policy
    Vouch.configuration.authentication_policy = RequestPolicy
    account = build(:account)

    controller.send(:authentication_allowed?, account, { 'method' => 'password' })
    controller.send(:needs_second_factor?, account, { 'method' => 'password' })

    expect(RequestPolicy.instances).to contain_exactly(an_instance_of(RequestPolicy))
  ensure
    Vouch.configuration.authentication_policy = original_policy
  end

  it 'diagnoses an explicit 2FA association without the account marker only in the built-in policy' do
    account_class = Class.new do
      def self.auth_feature_enabled?(_feature) = false
      def two_factor_enabled? = true
    end
    account = account_class.new
    mapping = double(two_factor_association_configured?: true)
    allow(controller).to receive(:auth_mapping).and_return(mapping)

    expect {
      controller.send(:needs_second_factor?, account, { 'method' => 'password' })
    }.to raise_error(Vouch::ConfigurationError, /authenticates_with.*two_factorable|custom authentication policy/i)

    custom_policy = Class.new do
      def two_factor_required?(*); false; end
      def allowed?(*); true; end
    end.new
    original_policy = Vouch.configuration.authentication_policy
    Vouch.configuration.authentication_policy = custom_policy
    custom_controller = Users::SessionsController.new
    allow(custom_controller).to receive(:auth_mapping).and_return(mapping)
    expect(custom_controller.send(:needs_second_factor?, account, { 'method' => 'password' })).to be(false)
  ensure
    Vouch.configuration.authentication_policy = original_policy if defined?(original_policy)
  end

  it 'R19 builds an identity with the configured account association' do
    mapping = Vouch::Mapping.new(:owner, account: 'Account', identity: 'User')
    allow(controller).to receive(:auth_mapping).and_return(mapping)
    account = create(:account)
    identity = controller.send(:build_identity, account, tenant: nil)
    expect(identity.account).to eq(account)
  end

  it 'R4 rejects a password changed between primary authentication and completion' do
    account = create(:account)
    create(:user, account: account)
    Account.find(account.id).update!(password: 'rotated-password')
    expect(proxy).not_to receive(:set_user)
    expect(controller.send(:complete_sign_in, account)).to eq(:denied)
  end

  it 'R25 forwards a direct completion block to the lifecycle environment' do
    account = create(:account)
    create(:user, account: account)
    allow(proxy).to receive(:set_user)
    allow(controller).to receive(:run_hooks).and_wrap_original do |method, *args, &block|
      method.call(*args, &block)
    end
    called = false
    expect(controller.send(:complete_sign_in, account) { |env| called = env.respond_to?(:add) }).to eq(:signed_in)
    expect(called).to be true
  end

  it 'clears the primary credential marker after direct completion' do
    account = create(:account)
    create(:user, account: account)
    credential = account.two_factor_credentials.create!(
      otp_secret: ROTP::Base32.random,
      verified_at: Time.current,
      two_factor_enabled_at: Time.current
    )
    allow(controller).to receive(:needs_second_factor?).and_return(false)
    allow(proxy).to receive(:set_user)
    session[controller.send(:signed_in_via_session_key)] = { 'type' => 'Stale', 'id' => '1' }

    expect(controller.send(:complete_sign_in, account, signed_in_via: credential)).to eq(:signed_in)
    expect(session).not_to have_key(controller.send(:signed_in_via_session_key))
  end

  it 'carries an account-owned primary credential through an MFA challenge' do
    account = create(:account)
    create(:user, account: account)
    credential = account.two_factor_credentials.create!(
      otp_secret: ROTP::Base32.random,
      verified_at: Time.current,
      two_factor_enabled_at: Time.current
    )
    allow(controller).to receive(:needs_second_factor?).and_return(true)

    expect(controller.send(:complete_sign_in, account, method: :magic_link, signed_in_via: credential)).to eq(:needs_two_factor)
    expect(session[controller.send(:signed_in_via_session_key)]).to include(
      'type' => credential.class.name,
      'id' => credential.id.to_s
    )
  end

  it 'does not let a foreign primary reference hide this account credentials' do
    account = create(:account)
    create(:user, account: account)
    own_credential = account.two_factor_credentials.create!(
      otp_secret: ROTP::Base32.random,
      verified_at: Time.current,
      two_factor_enabled_at: Time.current
    )
    foreign_account = create(:account)
    foreign_credential = foreign_account.two_factor_credentials.create!(
      otp_secret: ROTP::Base32.random,
      verified_at: Time.current,
      two_factor_enabled_at: Time.current
    )
    allow(controller).to receive(:needs_second_factor?).and_return(true)

    expect(controller.send(:complete_sign_in, account, method: :magic_link, signed_in_via: foreign_credential)).to eq(:needs_two_factor)
    expect(controller.send(:two_factor_credentials_for, account)).to include(own_credential)
  end
end
