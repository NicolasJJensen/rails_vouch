require 'rails_helper'

RSpec.describe 'Review: authentication integration boundaries', type: :request do
  def preserve_hooks(controller, hook)
    original = controller.public_send("_#{hook}_hooks").dup
    yield
  ensure
    controller.public_send("_#{hook}_hooks=", original)
  end

  it 'does not report Warden authentication before the second factor completes' do
    account = create(:account)
    create(:user, account: account)
    credential = account.two_factor_credentials.create!(verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    delivered = nil
    allow_any_instance_of(TwoFactorCredential).to receive(:deliver_two_factor_code) { |_record, code| delivered = code }
    events = []
    callbacks = Warden::Manager._after_set_user.dup
    Warden::Manager.after_authentication do |record, proxy, options|
      events << [record.class.name, options[:scope], options[:store]]
    end
    post '/users/sign_in', params: { email_address: account.email_address, password: 'password123' }
    expect(response).to redirect_to('/users/two_factor_challenges')
    expect(events).to eq([])
    get "/users/two_factor_challenges/#{credential.id}"
    patch "/users/two_factor_challenges/#{credential.id}", params: {code: delivered}
    expect(response).to redirect_to("/")
    expect(events).to eq([["User", :user, true]])
  ensure
    Warden::Manager._after_set_user.replace(callbacks) if callbacks
  end

  it 'consumes a magic sign-in code at most once' do
    phone = PhoneVerification.create!(e164: '+61400009991')
    issued = phone.issue_sign_in_code!
    code = phone.last_delivered_sign_in_code
    expect(phone.verify_sign_in_code(code, token: issued.token)).to be_ok
    expect(phone.reload.verify_sign_in_code(code, token: issued.token)).to be_invalid
  end

  it 'does not accept a verification token after explicit unverification' do
    phone = PhoneVerification.create!(e164: '+61400009992')
    issued = phone.start_verification!
    code = phone.last_delivered_code
    expect(phone.complete_verification!(code, token: issued.token)).to be_ok
    phone.unverify!
    expect(phone.complete_verification!(code, token: issued.token)).to be_invalid
  end

  it 'consumes a second-factor code at most once' do
    account = create(:account)
    credential = account.two_factor_credentials.create!(verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    delivered = nil
    credential.define_singleton_method(:deliver_two_factor_code) { |code| delivered = code }
    issued = credential.challenge!
    expect(credential.verify_challenge(delivered, token: issued.token)).to be_ok
    expect(credential.reload.verify_challenge(delivered, token: issued.token)).to be_invalid
  end

  it 'rejects a replay of the pending 2FA cookie and already consumed code' do
    account = create(:account)
    create(:user, account: account)
    credential = account.two_factor_credentials.create!(verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    delivered = nil
    allow_any_instance_of(TwoFactorCredential).to receive(:deliver_two_factor_code) { |_record, code| delivered = code }
    post '/users/sign_in', params: { email_address: account.email_address, password: 'password123' }
    get "/users/two_factor_challenges/#{credential.id}"
    session_key = Rails.application.config.session_options[:key]
    original_cookie = cookies[session_key]
    patch "/users/two_factor_challenges/#{credential.id}", params: { code: delivered }
    expect(response).to redirect_to('/')
    cookies[session_key] = original_cookie
    patch "/users/two_factor_challenges/#{credential.id}", params: { code: delivered }
    expect(response).not_to redirect_to('/')
  end
  it 'denies authentication when a lifecycle hook halts' do
    account = create(:account, failed_attempts: 3)
    create(:user, account: account)
    preserve_hooks(Users::SessionsController, :sign_in) do
      Users::SessionsController.before_sign_in { throw(:abort) }
      post '/users/sign_in', params: {email_address: account.email_address, password: 'password123'}
    end
    expect(response).not_to redirect_to('/')
    get '/users/sign_in'
    expect(response).to have_http_status(:ok)
    expect(account.reload.failed_attempts).to eq(3)
  end

  it 'reports a failure when a host callback prevents credential deletion' do
    user = create(:user)
    credential = user.account.two_factor_credentials.create!
    callback = proc { throw :abort }
    TwoFactorCredential.set_callback(:destroy, :before, callback)
    sign_in(user)
    delete "/users/two_factor_credentials/#{credential.id}"
    expect(TwoFactorCredential.exists?(credential.id)).to be true
    expect(flash[:notice]).not_to eq(I18n.t('vouch.two_factor_credentials.removed'))
  ensure
    TwoFactorCredential.skip_callback(:destroy, :before, callback) if callback
  end
  it 'keeps the final identity scope unauthenticated inside sign-in hooks' do
    account = create(:account)
    create(:user, account: account)
    observed = nil
    preserve_hooks(Users::SessionsController, :sign_in) do
      Users::SessionsController.before_sign_in do
        observed = warden.authenticated?(:user)
      end
      post '/users/sign_in', params: {email_address: account.email_address, password: 'password123'}
    end
    expect(response).to redirect_to('/')
    expect(observed).to be false
  end

end
