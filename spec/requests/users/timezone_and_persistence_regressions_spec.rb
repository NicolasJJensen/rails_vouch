require 'rails_helper'

RSpec.describe 'Authentication across host callbacks and time zones', type: :request do
  it 'preserves an established session when the host changes its time zone' do
    account = create(:account)
    create(:user, account: account)
    Time.use_zone('UTC') do
      post '/users/sign_in', params: {email_address: account.email_address, password: 'password123'}
      expect(response).to redirect_to('/')
    end
    Time.use_zone('Brisbane') do
      get '/users/two_factor_credentials'
      expect(response).to have_http_status(:ok)
    end
  end

  it 'preserves a verified second factor through selection in another time zone' do
    account = create(:account)
    users = create_list(:user, 2, account: account)
    credential = account.two_factor_credentials.create!(verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    delivered = nil
    allow_any_instance_of(TwoFactorCredential).to receive(:deliver_two_factor_code) { |_record, code| delivered = code }
    Time.use_zone('UTC') do
      post '/users/sign_in', params: {email_address: account.email_address, password: 'password123'}
      get "/users/two_factor_challenges/#{credential.id}"
      patch "/users/two_factor_challenges/#{credential.id}", params: {code: delivered}
      expect(response).to redirect_to('/users/select')
    end
    Time.use_zone('Brisbane') do
      post '/users/select', params: {identity_id: users.first.id}
      expect(response).to redirect_to('/')
      get '/users/two_factor_credentials'
      expect(response).to have_http_status(:ok)
    end
  end

  it 'does not authenticate when a second-factor callback cancels proof consumption' do
    account = create(:account)
    create(:user, account: account)
    credential = account.two_factor_credentials.create!(verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    delivered = nil
    allow_any_instance_of(TwoFactorCredential).to receive(:deliver_two_factor_code) { |_record, code| delivered = code }
    post '/users/sign_in', params: {email_address: account.email_address, password: 'password123'}
    get "/users/two_factor_challenges/#{credential.id}"
    nonce = credential.reload.two_factor_nonce
    callback = proc { raise ActiveRecord::Rollback }
    TwoFactorCredential.set_callback(:update, :before, callback)
    patch "/users/two_factor_challenges/#{credential.id}", params: {code: delivered}
    expect(response).to have_http_status(:unprocessable_content)
    expect(credential.reload.two_factor_nonce).to eq(nonce)
    get '/users/two_factor_credentials'
    expect(response).to redirect_to('/users/sign_in')
  ensure
    TwoFactorCredential.skip_callback(:update, :before, callback) if callback
  end
  it 'does not authenticate when an account callback cancels login bookkeeping' do
    account = create(:account, failed_attempts: 2)
    create(:user, account: account)
    callback = proc { raise ActiveRecord::Rollback }
    Account.set_callback(:update, :before, callback)
    post '/users/sign_in', params: {email_address: account.email_address, password: 'password123'}
    expect(response).to have_http_status(:unprocessable_content)
    expect(account.reload.failed_attempts).to eq(2)
    get '/users/two_factor_credentials'
    expect(response).to redirect_to('/users/sign_in')
  ensure
    Account.skip_callback(:update, :before, callback) if callback
  end

end
