require 'rails_helper'

RSpec.describe 'Authentication boundaries', type: :request do
  def login(account)
    post '/users/sign_in', params: { email_address: account.email_address, password: 'password123' }
  end

  def credential(account, enabled: true)
    account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: enabled ? Time.current : nil)
  end

  def signed_in_identity
    get '/users/two_factor_credentials'
    request.env['action_controller.instance'].send(:current_identity) if response.successful?
  end

  it 'R1 does not revoke ordinary identities without a token' do
    operator = create(:user)
    login(operator.account)
    expect { delete '/users/invitation' }.not_to change(User, :count)
  end

  it 'R1 does not revoke another inviters invitation' do
    operator = create(:user)
    invitation = create(:user, :invited, inviter: create(:user))
    login(operator.account)
    expect { delete '/users/invitation', params: {invitation_token: invitation.invitation_token} }.not_to change(User, :count)
  end

  it 'R1 clears an existing single-model account invitation without deleting the account' do
    operator = create(:user)
    invitation = create(:user, :invited, inviter: operator, organisation: operator.organisation)
    login(operator.account)
    mapping = Vouch.mapping_for(:user).dup
    allow(mapping).to receive(:split_model?).and_return(false)
    allow_any_instance_of(Users::InvitationsController).to receive(:auth_mapping).and_return(mapping)
    expect {
      delete '/users/invitation', params: {invitation_token: invitation.invitation_token}
    }.not_to change(User, :count)
    expect(invitation.reload.invitation_token).to be_nil
  end

  it 'R2 rejects direct verification with a disabled credential' do
    user = create(:user)
    credential(user.account)
    disabled = credential(user.account, enabled: false)
    user.account.enable_two_factor!
    login(user.account)
    get "/users/two_factor_challenges/#{disabled.id}"
    patch "/users/two_factor_challenges/#{disabled.id}", params: {code: ROTP::TOTP.new(disabled.otp_secret).now}
    expect(signed_in_identity).to be_nil
  end

  it 'R3 retains candidate restrictions through selection' do
    account = create(:account)
    allowed = Array.new(2) { create(:user, account: account) }
    forbidden = create(:user, account: account)
    allow_any_instance_of(Users::SessionsController).to receive(:candidate_identities_for).and_return(User.where(id: allowed.map(&:id)))
    login(account)
    expect(response).to redirect_to('/users/select')
    post '/users/select', params: {identity_id: forbidden.id}
    expect(signed_in_identity).to be_nil
  end

  it 'R4 rejects pending authentication after password rotation' do
    user = create(:user)
    factor = credential(user.account)
    login(user.account)
    user.account.update!(password: 'replacement123', password_confirmation: 'replacement123')
    get "/users/two_factor_challenges/#{factor.id}"
    expect(response).to redirect_to('/users/sign_in')
  end

  it 'R4 rejects pending authentication after an account lock' do
    user = create(:user)
    factor = credential(user.account)
    login(user.account)
    user.account.update!(locked_at: Time.current, failed_attempts: 5)
    get "/users/two_factor_challenges/#{factor.id}"
    expect(response).to redirect_to('/users/sign_in')
    expect(user.account.reload).to be_locked
  end

  it 'R4 expires the first-factor proof even when a new challenge could be issued' do
    user = create(:user)
    factor = credential(user.account)
    login(user.account)
    travel 1.hour do
      get "/users/two_factor_challenges/#{factor.id}"
      expect(response).to redirect_to('/users/sign_in')
    end
  end

  it 'R9 consumes the exact password reset token emitted by the controller' do
    account = create(:account)
    token = nil
    allow_any_instance_of(Users::PasswordResetsController).to receive(:run_hooks).and_wrap_original do |method, *args, **opts, &block|
      token = args[2] if args[0] == :password_reset_token_generation
      method.call(*args, **opts, &block)
    end
    post '/users/password_reset', params: {email_address: account.email_address}
    expect(token).to be_present
    patch '/users/password_reset', params: {token: token, account: {password: 'replacement123', password_confirmation: 'replacement123'}}
    expect(account.reload.authenticate('replacement123')).to be_truthy
  end

  it 'R12 restores the original identity across real requests' do
    operator = create(:user)
    target = create(:user)
    allow_any_instance_of(Users::ImpersonationsController).to receive(:authorize_impersonation!).and_return(true)
    login(operator.account)
    post "/users/impersonations/#{target.id}"
    delete '/users/impersonations'
    expect(signed_in_identity).to eq(operator)
  end

  it 'R12 denies impersonation unless the host authorizes it' do
    operator = create(:user)
    target = create(:user)
    login(operator.account)
    post "/users/impersonations/#{target.id}"
    expect(response).to have_http_status(:forbidden)
  end

  it 'R12 refuses restoration after the original operators password is revoked' do
    operator = create(:user)
    target = create(:user)
    allow_any_instance_of(Users::ImpersonationsController).to receive(:authorize_impersonation!).and_return(true)
    login(operator.account)
    post "/users/impersonations/#{target.id}"
    operator.account.update!(password: 'rotated-password', password_confirmation: 'rotated-password')
    delete '/users/impersonations'
    expect(response).to have_http_status(422)
    expect(signed_in_identity).not_to eq(operator)
  end

  it 'R12 retains the original operator when switching impersonation targets' do
    operator, first, second = Array.new(3) { create(:user) }
    allow_any_instance_of(Users::ImpersonationsController).to receive(:authorize_impersonation!).and_return(true)
    login(operator.account)
    post "/users/impersonations/#{first.id}"
    post "/users/impersonations/#{second.id}"
    expect(signed_in_identity).to eq(second)
    delete '/users/impersonations/all'
    expect(signed_in_identity).to eq(operator)
  end

  it 'policy requires local 2FA for OAuth by default' do
    user = create(:user)
    credential(user.account)
    user.account.enable_two_factor!
    user.account.omni_auth_identities.create!(provider: 'review', uid: 'subject', auth_data: '{}')
    auth = OmniAuth::AuthHash.new(provider: 'review', uid: 'subject', info: {email: user.email_address})
    get '/users/auth/review/callback', env: {'omniauth.auth' => auth}
    expect(response).to redirect_to('/users/two_factor_challenges')
  end

  it 'policy rejects a locked OAuth account' do
    user = create(:user)
    user.account.update!(locked_at: Time.current, failed_attempts: 5)
    user.account.omni_auth_identities.create!(provider: 'review', uid: 'subject', auth_data: '{}')
    auth = OmniAuth::AuthHash.new(provider: 'review', uid: 'subject', info: {email: user.email_address})
    get '/users/auth/review/callback', env: {'omniauth.auth' => auth}
    expect(signed_in_identity).to be_nil
  end
end

RSpec.describe 'Invitation completion', type: :request do
  it 'R13 reuses an existing account and accepts only after its login and identity selection' do
    operator = create(:user)
    existing = create(:user)
    post '/users/sign_in', params: {email_address: operator.email_address, password: 'password123'}
    expect {
      post '/users/invitation', params: {email_address: " #{existing.email_address.upcase} "}
    }.not_to change(Account, :count)
    invitation = User.where(account: existing.account).where.not(invitation_token: nil).sole
    expect(invitation.account).not_to be_registration_required
    expect(invitation.organisation).to eq(operator.organisation)
    delete '/users/sign_out'
    get '/users/invitation/accept', params: {token: invitation.invitation_token}
    expect(invitation.reload.invitation_token).to be_present
    post '/users/sign_in', params: {email_address: existing.email_address, password: 'password123'}
    expect(response).to redirect_to('/users/select')
    post '/users/select', params: {identity_id: invitation.id}
    expect(response).to redirect_to('/')
    expect(invitation.reload.invitation_token).to be_nil
  end

  it 'R13 accepts an existing-account invitation only after MFA and identity selection' do
    operator = create(:user)
    existing = create(:user)
    post '/users/sign_in', params: {email_address: operator.email_address, password: 'password123'}
    post '/users/invitation', params: {email_address: existing.email_address}
    invitation = User.where(account: existing.account).where.not(invitation_token: nil).sole
    factor = existing.account.two_factor_credentials.create!(
      otp_secret: ROTP::Base32.random,
      verified_at: Time.current,
      two_factor_enabled_at: Time.current
    )
    existing.account.enable_two_factor!

    delete '/users/sign_out'
    get '/users/invitation/accept', params: {token: invitation.invitation_token}
    expect(response).to redirect_to('/users/sign_in')

    post '/users/sign_in', params: {email_address: existing.email_address, password: 'password123'}
    expect(response).to redirect_to('/users/two_factor_challenges')
    get "/users/two_factor_challenges/#{factor.id}"
    patch "/users/two_factor_challenges/#{factor.id}", params: {code: ROTP::TOTP.new(factor.otp_secret).now}

    expect(response).to redirect_to('/users/select')
    expect(invitation.reload.invitation_token).to be_present
    post '/users/select', params: {identity_id: invitation.id}

    expect(response).to redirect_to('/')
    expect(invitation.reload.invitation_token).to be_nil
    expect(invitation.invitation_accepted_at).to be_present
  end

  it 'R13 completes the invited account without creating another tenant or identity' do
    identity = create(:user, :invited)
    identity.account.update!(registration_required: true)
    original_counts = [Account.count, User.count, Organisation.count]
    get '/users/invitation/accept', params: {token: identity.invitation_token}
    post '/users/sign_up', params: {account: {email_address: identity.email_address,
      password: 'newpassword123', password_confirmation: 'newpassword123'}}
    expect([Account.count, User.count, Organisation.count]).to eq(original_counts)
    expect(identity.reload.invitation_token).to be_nil
    expect(identity.account.reload.authenticate('newpassword123')).to be_truthy
  end

  it 'R13 requires authentication for an existing account invitation' do
    identity = create(:user, :invited)
    get '/users/invitation/accept', params: {token: identity.invitation_token}
    expect(response).to redirect_to('/users/sign_in')
    post '/users/sign_up', params: {account: {password: 'attacker123', password_confirmation: 'attacker123'}}
    expect(identity.account.reload.authenticate('attacker123')).to be false
  end

  it 'R13 rejects a revoked invitation retained in the session' do
    identity = create(:user, :invited)
    identity.account.update!(registration_required: true)
    get '/users/invitation/accept', params: {token: identity.invitation_token}
    identity.update!(invitation_token: nil)
    post '/users/sign_up', params: {account: {password: 'attacker123', password_confirmation: 'attacker123'}}
    expect(identity.account.reload.authenticate('attacker123')).to be false
  end
end

RSpec.describe 'Hook and session contracts', type: :request do
  def preserve_hooks(controller, hook)
    original = controller.__hooks
    yield
  ensure
    controller.__hooks = original if original
  end

  it 'does not claim logout succeeded when its lifecycle hook aborts' do
    user = create(:user)
    post '/users/sign_in', params: {email_address: user.email_address, password: 'password123'}
    preserve_hooks(Users::SessionsController, :sign_out) do
      Users::SessionsController.before_sign_out { throw(:abort) }
      delete '/users/sign_out'
    end
    expect(response).to have_http_status(:forbidden)
    get '/users/two_factor_credentials'
    expect(response).to have_http_status(:ok)
  end

  it 'rolls back the account and tenant if registration cannot create its identity' do
    allow_any_instance_of(Users::RegistrationsController).to receive(:build_identity) do
      raise ActiveRecord::RecordInvalid.new(User.new)
    end
    counts = [Account.count, Organisation.count, User.count]
    post '/users/sign_up', params: {account: {email_address: 'rollback@example.com', password: 'password123'}}
    expect(response).to have_http_status(422)
    expect([Account.count, Organisation.count, User.count]).to eq(counts)
  end

  it 'does not persist registration when its lifecycle hook aborts' do
    preserve_hooks(Users::RegistrationsController, :sign_up) do
      Users::RegistrationsController.before_sign_up { throw(:abort) }
      expect {
        post '/users/sign_up', params: {account: {email_address: 'aborted@example.com', password: 'password123'}}
      }.not_to change(Account, :count)
    end
    expect(response).to have_http_status(:forbidden)
  end

  it 'R25 reports a denied login when a before hook aborts' do
    user = create(:user)
    preserve_hooks(Users::SessionsController, :sign_in) do
      Users::SessionsController.before_sign_in { throw(:abort) }
      post '/users/sign_in', params: {email_address: user.email_address, password: 'password123'}
    end
    expect(response).not_to redirect_to('/')
    get '/users/two_factor_credentials'
    expect(response).to redirect_to('/users/sign_in')
  end

  it 'R24 assigns separate session keys to credential models with the same ID' do
    controller = Users::SessionsController.new
    first = TwoFactorCredential.new(id: 1)
    second = PhoneVerification.new(id: 1)
    expect(controller.send(:two_factor_token_session_key, first)).not_to eq(controller.send(:two_factor_token_session_key, second))
  end
end

RSpec.describe 'Second-factor completion hooks', type: :request do
  def preserve_hooks(controller, hook)
    original = controller.__hooks
    yield
  ensure
    controller.__hooks = original if original
  end

  it 'R25 carries the verified credential through identity selection to the two-factor hook' do
    account = create(:account)
    identities = Array.new(2) { create(:user, account: account) }
    factor = account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    hook_credential = nil
    preserve_hooks(Users::MembershipSessionsController, :two_factor_verification) do
      Users::MembershipSessionsController.on_two_factor_verification do |_account, _identity, credential|
        hook_credential = credential
      end
      post '/users/sign_in', params: {email_address: account.email_address, password: 'password123'}
      get "/users/two_factor_challenges/#{factor.id}"
      patch "/users/two_factor_challenges/#{factor.id}", params: {code: ROTP::TOTP.new(factor.otp_secret).now}
      expect(response).to redirect_to('/users/select')
      post '/users/select', params: {identity_id: identities.first.id}
    end
    expect(response).to redirect_to('/')
    expect(hook_credential).to eq(factor)
  end

  it 'R2 refuses a factor disabled after verification but before selection' do
    account = create(:account)
    identities = Array.new(2) { create(:user, account: account) }
    factor = account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    post '/users/sign_in', params: {email_address: account.email_address, password: 'password123'}
    get "/users/two_factor_challenges/#{factor.id}"
    patch "/users/two_factor_challenges/#{factor.id}", params: {code: ROTP::TOTP.new(factor.otp_secret).now}
    factor.update_column(:two_factor_enabled_at, nil)
    post '/users/select', params: {identity_id: identities.first.id}
    get '/users/two_factor_credentials'
    expect(response).to redirect_to('/users/sign_in')
  end
end
